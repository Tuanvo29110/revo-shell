pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Io
import "../modules/common"

Singleton {
    id: root

    readonly property string iconsDir: Qt.resolvedUrl("../assets/icons/").toString()
    readonly property string iconScript: Qt.resolvedUrl("../scripts/dock_icon.sh").toString().replace(/^file:\/\//, "")
    readonly property string killScript: Qt.resolvedUrl("../scripts/kill_app.sh").toString().replace(/^file:\/\//, "")

    // Pinned apps come from ~/.config/revo-shell/dock.json (written by
    // scripts/dock_setup.py from the apps installed on this machine, and
    // rewritten here whenever you pin / unpin / reorder). Until it exists the
    // Dock shows this minimal set and generates the file once, automatically.
    property var pinned: [
        { name: "Finder", icon: "Finder.png", desktop: "org.gnome.Nautilus", exec: "nautilus", appIds: ["org.gnome.Nautilus", "nautilus"] },
        { name: "Launchpad", icon: "Apps.png", desktop: "macos-launcher", exec: "qs ipc -p $HOME/.config/quickshell/macos call launchpad toggle", appIds: ["macos-launcher", "Launcher"] },
        { name: "Terminal", icon: "Terminal.png", desktop: "kitty", exec: "kitty", appIds: ["kitty"] },
        { name: "System Settings", icon: "System Settings.png", desktop: "systemsettings", exec: "$HOME/.local/bin/systemsettings", appIds: ["systemsettings", "macos-settings", "pearos-settings", "pearos-settings-app"] },
    ]

    readonly property string dockFile: Quickshell.env("HOME") + "/.config/revo-shell/dock.json"
    readonly property string dockSetup: Qt.resolvedUrl("../scripts/dock_setup.py").toString().replace(/^file:\/\//, "")
    property bool _dockLoaded: false
    FileView {
        id: _dockFile
        path: root.dockFile
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const d = JSON.parse(text());
                if (d && Array.isArray(d.pinned) && d.pinned.length) {
                    root.pinned = d.pinned.filter(p => p && p.name && Array.isArray(p.appIds));
                }
            } catch (e) {
                console.warn("dock.json unreadable:", e);
            }
            root._dockLoaded = true;
        }
        onLoadFailed: (err) => {
            if (err === FileViewError.FileNotFound && !_dockGen.running) _dockGen.running = true;
        }
    }
    Process {
        id: _dockGen
        command: ["python3", "-I", root.dockSetup, "--auto", "--keep"]
        stdout: StdioCollector { onStreamFinished: _dockFile.reload() }
    }
    function saveDock() {
        if (!root._dockLoaded) return;
        _dockFile.setText(JSON.stringify({ version: 1, pinned: root.pinned }, null, 2));
    }

    // ── Downloads stack (IPC + diagnostics) ──
    property bool downloadsOpen: false
    property string stackState: ""
    property var stackOpen: null
    // set by Dock.qml: maps a window class to the icon's local centre "x,y"
    property var iconLocalPos: null

    property var runningApps: []
    readonly property var dockItems: root.pinned.concat(root.runningApps)
    property var _running: []
    property var _iconCache: ({})
    property var darkSet: ({})
    property var tintSet: ({})
    property bool _tintBusy: false
    property string _tintFor: ""
    property bool _iconBusy: false
    property bool _iconDone: false
    property var _iconProc: null
    property string _iconId: ""
    property string _signature: ""
    // unread counts from notifications, kept until the app is focused
    property var notificationBadges: ({})
    readonly property string minScript: "/home/revo/.config/hypr/scripts/minimize_window.py"
    property var _focusIds: []

    // windows genie-minimized into the Dock (thumbnails between apps and separator)
    property var _minAll: []
    // Desktop & Dock › "Minimize windows into application icon": no separate
    // tiles — clicking the app icon restores them (hasmin/clickrestore)
    readonly property var minimizedItems:
        ((Appearance.userCfg || {}).dock || {}).minimizeIntoIcon === true ? [] : root._minAll
    property string _minStatePath: "/home/revo/.cache/hypr_minimized.json"

    // minimize_window.py replaces this file atomically on every change
    FileView {
        path: root._minStatePath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root._onMinJson(text())
        onLoadFailed: root._minAll = []
    }

    function _onMinJson(text) {
        try {
            const arr = JSON.parse((text || "").trim() || "[]");
            if (!Array.isArray(arr)) throw new Error("bad json");
            const items = [];
            for (const e of arr) {
                if (e && e.addr && e.class) {
                    items.push({
                        addr: e.addr,
                        cls: e.class,
                        title: e.title || e.class,
                        thumb: e.thumb || ""
                    });
                }
            }
            root._minAll = items;
        } catch (e) {
            root._minAll = [];
        }
    }

    // dock click: probe whether the app has genie-minimized windows, then
    // either restore them (the script focuses the restored window) or activate
    Process {
        id: _restoreProbe
        running: false
        stdout: StdioCollector {
            onStreamFinished: root._onHasMin(text)
        }
    }
    Process {
        id: _restoreProc
        running: false
        stdout: StdioCollector {}
    }

    function _onHasMin(text) {
        const ids = root._focusIds || [];
        if ((text || "").trim() === "1") {
            _restoreProc.running = false;
            _restoreProc.command = ["python3", root.minScript, "clickrestore"].concat(ids);
            _restoreProc.running = true;
            return; // restore brings it back and focuses it
        }
        for (const t of ToplevelManager.toplevels.values) {
            if (ids.includes(t.appId)) {
                if (typeof t.activate === "function") t.activate();
                return;
            }
        }
    }

    // only a bracketed number is a badge: (3), [12], (99+), (17,761).
    // A bare four-digit 19xx / 20xx in brackets is a year.
    function _titleCount(title) {
        const re = /[\(\[](\d+(?:,\d{3})*)\+?[\)\]]/g;
        let m;
        while ((m = re.exec(title || "")) !== null) {
            if (/^(19|20)\d\d$/.test(m[1])) continue;
            const count = parseInt(m[1].replace(/,/g, ""), 10);
            if (count > 0) return count;
        }
        return 0;
    }

    // badge key (appIds[0]) of the Dock item a window class or app name belongs to
    function _badgeKey(name) {
        const n = String(name || "").trim().toLowerCase();
        if (!n) return "";
        for (const it of root.dockItems) {
            if (it.appIds.some(id => String(id).toLowerCase() === n)) return it.appIds[0];
        }
        for (const it of root.dockItems) {
            // empty fields must be skipped: every string includes ""
            if ([it.name, it.exec, it.desktop].some(v => {
                const s = String(v || "").toLowerCase();
                return s !== "" && (n.includes(s) || s.includes(n));
            })) return it.appIds[0];
        }
        return "";
    }

    // counts shown in window titles; re-evaluates when a window or title changes
    readonly property var titleBadges: {
        const counts = {};
        for (const t of ToplevelManager.toplevels.values) {
            const count = root._titleCount(t.title);
            if (count <= 0) continue;
            const key = root._badgeKey(root._normalizeId(t));
            if (key) counts[key] = Math.max(counts[key] || 0, count);
        }
        return counts;
    }

    function incrementBadge(appId) {
        const next = Object.assign({}, root.notificationBadges);
        next[appId] = (next[appId] || 0) + 1;
        root.notificationBadges = next;
    }

    function clearBadge(appId) {
        if (!(appId in root.notificationBadges)) return;
        const next = Object.assign({}, root.notificationBadges);
        delete next[appId];
        root.notificationBadges = next;
    }

    function badgeFor(appId) {
        return Math.max(root.titleBadges[appId] || 0, root.notificationBadges[appId] || 0);
    }

    // badge key of the Dock item that owns the focused window
    function _activeKey() {
        const id = ToplevelManager.activeToplevel?.appId;
        const item = id ? root.dockItems.find(it => it.appIds.includes(id)) : undefined;
        return item ? item.appIds[0] : "";
    }

    function pinApp(app) {
        // Check if already pinned
        for (const p of root.pinned) {
            if (p.appIds[0] === app.appIds[0]) return;
        }
        root.pinned.push({
            name: app.name,
            icon: app.icon || app.name + ".png",
            desktop: app.desktop || "",
            exec: app.exec || "",
            appIds: app.appIds || [app.name]
        });
        root.pinned = root.pinned;
        root.saveDock();
        // Remove from running apps if present
        root.runningApps = root.runningApps.filter(r => r.appIds[0] !== app.appIds[0]);
        Qt.callLater(root.refresh);
    }

    function unpinApp(app) {
        root.pinned = root.pinned.filter(p => p.appIds[0] !== app.appIds[0]);
        root.saveDock();
    }

    function isPinned(appId) {
        for (const p of root.pinned) {
            if (p.appIds.includes(appId)) return true;
        }
        return false;
    }

    function movePinned(fromIndex, toIndex) {
        if (fromIndex === toIndex) return;
        if (fromIndex < 0 || fromIndex >= root.pinned.length) return;
        if (toIndex < 0 || toIndex >= root.pinned.length) return;
        const item = root.pinned[fromIndex];
        const arr = root.pinned.slice();
        arr.splice(fromIndex, 1);
        arr.splice(toIndex, 0, item);
        root.pinned = arr;
        root.saveDock();
    }

    function pinnedIcon(appId) {
        for (const p of root.pinned) {
            if (p.appIds.includes(appId)) return p.icon;
        }
        return "";
    }

    function iconSource(icon) {
        if (!icon) return "";
        const isUrl = icon.startsWith("file://") || icon.startsWith("http") || icon.startsWith("image://");
        const base = icon.split("/").pop();
        if (Appearance.iconTintActive && root.tintSet[base] && root._tintFor === root.tintSlug)
            return root.tintDirUrl + base;
        if (Appearance.effectiveIconStyle === "Dark") {
            if (root.darkSet[base])
                return root.iconsDir + "dark/" + base;
        }
        if (isUrl) return icon;
        return root.iconsDir + icon;
    }

    // downloads folder: tinted when a tint colour is active, otherwise the SVG
    function folderSource() {
        const base = "folder-downloads.png";
        if (root.tintDirUrl.length > 0 && root.tintSet[base] && root._tintFor === root.tintSlug)
            return root.tintDirUrl + base;
        return root.iconsDir + "folder-downloads.svg";
    }

    function iconFor(appId) {
        return root._iconCache[appId] || root.pinnedIcon(appId) || "Placeholder.png";
    }

    function iconForClass(cls) {
        if (!cls) return "";
        const c = String(cls).toLowerCase();
        for (const it of root.dockItems) {
            for (const id of (it.appIds || [])) {
                if (String(id || "").toLowerCase() === c) return root.iconFor(id);
            }
        }
        return "";
    }

    // The shell's own windows all report appId "org.quickshell".
    // Map them onto the dock entry they belong to so they never show up
    // as a separate "quickshell" icon.
    function _normalizeId(t) {
        const id = t.appId;
        if (!id) return "";
        if (id === "org.quickshell" || id === "quickshell") {
            const title = (t.title || "").toLowerCase().replace(/\s+/g, "");
            if (title.indexOf("systemsettings") !== -1) return "macos-settings";
            return "";
        }
        return id;
    }

    function allRunningIds() {
        const ids = [];
        for (const t of ToplevelManager.toplevels.values) {
            const id = root._normalizeId(t);
            if (id && !ids.includes(id)) ids.push(id);
        }
        return ids;
    }

    function isRunning(appIds) {
        // The launchpad is a shell surface, not an xdg toplevel: mirror its
        // open state so the dock shows it as a running app and stops bouncing.
        if (appIds.includes("macos-launcher")) return ShellController.launcherOpen;
        for (const id of appIds) {
            if (root._running.includes(id)) return true;
        }
        return false;
    }

    function focusApp(appIds) {
        for (const id of appIds) {
            root.clearBadge(id);
        }
        if (appIds.includes("macos-launcher")) {
            ShellController.toggle("launcher");
            return;
        }
        root._focusIds = appIds.slice();
        _restoreProbe.running = false;
        _restoreProbe.command = ["python3", root.minScript, "hasmin"].concat(appIds);
        _restoreProbe.running = true;
    }

    function quitApp(appIds) {
        for (const t of ToplevelManager.toplevels.values) {
            if (appIds.includes(t.appId)) {
                if (typeof t.close === "function") t.close();
            }
        }
    }

    function forceKillApp(appIds) {
        _killProc.command = ["bash", root.killScript].concat(appIds);
        _killProc.running = true;
    }

    function _friendlyName(id) {
        const seg = id.split(".").pop();
        return seg.charAt(0).toUpperCase() + seg.slice(1).replace(/[-_]/g, " ");
    }

    function _resolveIcons() {
        if (root._iconBusy) return;
        for (const item of root.runningApps) {
            const id = item.appIds[0];
            if (!(id in root._iconCache) || root._iconCache[id] === null) {
                root._iconCache[id] = null;
                root._requestIcon(id);
                return;
            }
        }
    }

    function _requestIcon(id) {
        if (root._iconBusy) return;
        root._iconBusy = true;
        root._iconId = id;
        const cmd = root.iconScript + " '" + id.replace(/'/g, "'\\''") + "'";
        root._iconProc = Qt.createQmlObject(`
            import Quickshell.Io
            Process {
                command: ${JSON.stringify(["bash", "-c", cmd])}
                running: true
                stdout: StdioCollector {
                    onStreamFinished: root._iconResolved(${JSON.stringify(id)}, text)
                }
            }`, root, "iconProc");
        _iconFailSafe.restart();
    }

    function _iconResolved(id, text) {
        if (root._iconDone) return;
        root._iconDone = true;
        if (root._iconProc) {
            root._iconProc.destroy();
            root._iconProc = null;
        }
        root._iconBusy = false;
        const path = text.trim();
        if (path) {
            root._iconCache[id] = "file://" + path;
            root.runningApps = root._buildExtras();
        } else {
            root._iconCache[id] = "";
        }
        root._iconDone = false;
        _iconFailSafe.stop();
        root._resolveIcons();
    }

    Timer {
        id: _iconFailSafe
        interval: 8000
        repeat: false
        onTriggered: {
            if (root._iconBusy) {
                // give up on this id, otherwise it is picked again forever
                root._iconCache[root._iconId] = "";
                if (root._iconProc) {
                    root._iconProc.destroy();
                    root._iconProc = null;
                }
                root._iconBusy = false;
                root._resolveIcons();
            }
        }
    }

    function _buildExtras() {
        const extras = [];
        for (const id of root._running) {
            if (root.pinnedIcon(id)) continue;
            extras.push({
                name: root._friendlyName(id),
                icon: root.pinnedIcon(id) || root._iconCache[id] || "Placeholder.png",
                exec: id,
                appIds: [id],
                running: true
            });
        }
        return extras;
    }

    // changes whenever a window opens, closes or changes its app id
    readonly property string runningKey: root.allRunningIds().join("|")
    onRunningKeyChanged: Qt.callLater(root.refresh)
    onPinnedChanged: Qt.callLater(root.refresh)

    function refresh() {
        root._running = root.allRunningIds();

        const extras = root._buildExtras();

        const sig = extras.map(e => e.appIds[0]).join("|");
        if (sig !== root._signature) {
            root._signature = sig;
            root.runningApps = extras;
            root._resolveIcons();
        }
    }

    Process {
        id: _killProc
        running: false
        stdout: StdioCollector {}
    }

    // index of assets/icons/dark so the "Dark" icon style can swap in
    // the themed variant of every icon that has one.
    Process {
        id: _darkScan
        running: true
        command: ["bash", "-c", "ls -1 " + root.iconsDir.replace(/^file:\/\//, "") + "dark 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                const m = {};
                text.split("\n").forEach(function (l) {
                    const n = l.trim();
                    if (n) m[n] = true;
                });
                root.darkSet = m;
                console.log("ICON_DARK_SET " + Object.keys(m).length);
            }
        }
    }

    // Bake tinted artwork into assets/icons/tinted/<colour>/ with Python
    // (~2s, only the first time a colour is used) so tinted icons keep their
    // detail instead of being flattened by a runtime effect.
    readonly property string tintScript: Qt.resolvedUrl("../scripts/tint_icons.py").toString().replace(/^file:\/\//, "")
    readonly property string tintRoot: Qt.resolvedUrl("../assets/icons/tinted/").toString().replace(/^file:\/\//, "")
    readonly property url tintRootUrl: Qt.resolvedUrl("../assets/icons/tinted/")
    property string _tintBusyHex: ""

    // colour in use: the icon colour while Tinted, otherwise the folder colour
    readonly property string tintHex: {
        if (Appearance.iconTintActive)
            return String(Appearance.iconTint)
        const f = String(Appearance.folderColor || "")
        return f.length > 0 ? f : ""
    }
    readonly property string tintSlug: tintHex.replace("#", "").toLowerCase()
    readonly property string tintDirUrl: tintHex.length > 0 ? tintRootUrl.toString() + tintSlug + "/" : ""
    readonly property string tintDir: tintHex.length > 0 ? tintRoot + tintSlug + "/" : ""

    function _scheduleTint() {
        _tintTimer.restart();
    }

    function _runTint() {
        if (root.tintHex.length === 0) {
            root.tintSet = {};
            root._tintFor = "";
            return;
        }
        if (root._tintBusy) return;
        const hex = root.tintHex;
        if (root.tintSlug.length > 0 && root.tintSlug === root._tintFor && Object.keys(root.tintSet).length > 0)
            return;
        const plain = root.iconsDir.replace(/^file:\/\//, "");
        const dirs = plain + ":" + plain + "dark:" + plain + "light";
        // one folder per colour: bake only when that colour was never baked,
        // so switching to an already prepared colour is instant.
        root._tintBusy = true;
        root._tintBusyHex = hex;
        _tintProc.command = ["bash", "-c",
            "D='" + root.tintDir + "'; " +
            "if [ ! -f \"$D/.tint\" ]; then " +
            "nice -n 5 python3 '" + root.tintScript + "' '" + hex + "' '" + dirs + "' \"$D\"; " +
            "fi; ls -1 \"$D\" 2>/dev/null"];
        _tintProc.running = true;
    }

    Timer {
        id: _tintTimer
        interval: 350
        onTriggered: root._runTint()
    }

    Process {
        id: _tintProc
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                const m = {};
                text.split("\n").forEach(function (l) {
                    const n = l.trim();
                    if (n) m[n] = true;
                });
                root.tintSet = m;
                root._tintFor = root._tintBusyHex.replace("#", "").toLowerCase();
                root._tintBusy = false;
                console.log("ICON_TINT_SET " + Object.keys(m).length + " " + root._tintFor);
                if (root.tintSlug !== root._tintFor)
                    root._scheduleTint();
            }
        }
    }

    Connections {
        target: Appearance
        function onIconTintChanged() { root._scheduleTint(); }
        function onFolderColorChanged() { root._scheduleTint(); }
        function onEffectiveIconStyleChanged() { root._scheduleTint(); }
    }

    Connections {
        target: Notifications
        function onNotify(n) {
            const key = root._badgeKey(n.appName);
            if (key && key !== root._activeKey()) root.incrementBadge(key);
        }
    }

    Connections {
        target: ToplevelManager
        function onActiveToplevelChanged() { root.clearBadge(root._activeKey()); }
    }

    Component.onCompleted: {
        root.refresh();
        root._scheduleTint();
    }
}
