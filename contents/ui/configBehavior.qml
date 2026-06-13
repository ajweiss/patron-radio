import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.bluezqt as BluezQt

import "../imports/com/signal11/patronradio" as RadioBackendModule

Item {
    id: behaviorRoot
    Layout.fillWidth: true
    Layout.fillHeight: true

    property alias cfg_autoLocalStation: autoLocalCheckbox.checked
    property alias cfg_autoplayOnStartup: autoplayCheckbox.checked
    property alias cfg_resumePlaybackOnRestart: resumePlaybackCheckbox.checked
    property alias cfg_pauseOnBtDisconnect: pauseOnBtDisconnectCheckbox.checked
    property alias cfg_inhibitSleep: inhibitSleepCheckbox.checked
    property alias cfg_normalizeLoudness: normalizeLoudnessCheckbox.checked
    property alias cfg_loudnessAuto: loudnessAutoCheckbox.checked

    // JSON configuration strings
    property string cfg_autoplayBluetoothDevices: "[]"
    property string cfg_outputPriorityDevices: "[]"
    
    property var btManager: BluezQt.Manager

    ListModel { id: priorityModel }
    ListModel { id: autoplayModel }

    Component.onCompleted: {
        refreshAll()
    }

    Connections {
        target: btManager
        function onOperationalChanged() { refreshAll() }
        function onDeviceChanged(device) { refreshAll() }
    }

    Connections {
        target: RadioBackendModule.RadioBackend
        function onAvailableOutputsChanged() { refreshAll() }
    }

    function refreshAll() {
        refreshPriorityModel()
        refreshAutoplayModel()
    }

    function refreshPriorityModel() {
        var saved = []
        try {
            var parsed = JSON.parse(cfg_outputPriorityDevices || "[]")
            saved = parsed.map(function(item) {
                return typeof item === 'string' ? { "id": item, "name": "" } : item;
            });
        } catch(e) {}
        
        priorityModel.clear()
        var systemOutputs = RadioBackendModule.RadioBackend.availableOutputs
        var needsSave = false;

        // 1. Add saved devices first (maintains user priority)
        for (var i = 0; i < saved.length; i++) {
            var savedItem = saved[i]
            var sysDev = null
            for (var j = 0; j < systemOutputs.length; j++) {
                if (systemOutputs[j].id === savedItem.id) {
                    sysDev = systemOutputs[j]
                    break
                }
            }
            
            var bestName = savedItem.name;
            if (sysDev && sysDev.name !== savedItem.name) {
                bestName = sysDev.name;
                needsSave = true; // Update stored name if system provided a better one
            }

            priorityModel.append({
                "deviceId": savedItem.id,
                "name": bestName || (savedItem.id.indexOf("bluez") !== -1 ? "Bluetooth Device" : "Offline Device"),
                "isOnline": !!sysDev
            })
        }
        
        // 2. Add new system outputs not yet in the list
        for (var k = 0; k < systemOutputs.length; k++) {
            var dev = systemOutputs[k]
            var alreadyIn = false
            for (var m = 0; m < priorityModel.count; m++) {
                if (priorityModel.get(m).deviceId === dev.id) {
                    alreadyIn = true
                    break
                }
            }
            if (!alreadyIn) {
                priorityModel.append({
                    "deviceId": dev.id,
                    "name": dev.name,
                    "isOnline": true
                })
                needsSave = true;
            }
        }

        if (needsSave) {
            savePriority();
        }
    }

    function refreshAutoplayModel() {
        var saved = []
        try {
            var parsed = JSON.parse(cfg_autoplayBluetoothDevices || "[]")
            saved = parsed.map(function(item) {
                return typeof item === 'string' ? item : item.address
            })
        } catch(e) {}
        
        autoplayModel.clear()
        for (var i = 0; i < btManager.devices.length; i++) {
            var dev = btManager.devices[i]
            var isAudio = false
            for (var j = 0; j < dev.uuids.length; j++) {
                var uuidStr = String(dev.uuids[j]).toUpperCase()
                if (uuidStr.indexOf("110B") !== -1 || uuidStr.indexOf("110E") !== -1 || uuidStr.indexOf("111E") !== -1) {
                    isAudio = true; break;
                }
            }
            if (isAudio) {
                autoplayModel.append({
                    "address": dev.address,
                    "name": dev.name,
                    "isChecked": saved.indexOf(dev.address) !== -1
                })
            }
        }
    }

    function savePriority() {
        var list = []
        for (var i = 0; i < priorityModel.count; i++) {
            var item = priorityModel.get(i)
            // Only save the name if it's not a generic placeholder
            var finalName = item.name;
            if (finalName === "Offline Device" || finalName === "Bluetooth Device") {
                finalName = "";
            }
            list.push({
                "id": item.deviceId,
                "name": finalName
            })
        }
        cfg_outputPriorityDevices = JSON.stringify(list)
    }

    function saveAutoplay() {
        var list = []
        for (var i = 0; i < autoplayModel.count; i++) {
            if (autoplayModel.get(i).isChecked) {
                list.push(autoplayModel.get(i).address)
            }
        }
        cfg_autoplayBluetoothDevices = JSON.stringify(list)
    }

    function movePriority(from, to) {
        if (to < 0 || to >= priorityModel.count) return
        priorityModel.move(from, to, 1)
        savePriority()
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: Kirigami.Units.largeSpacing + 3
        anchors.bottomMargin: Kirigami.Units.largeSpacing + 3
        anchors.leftMargin: Kirigami.Units.gridUnit
        anchors.rightMargin: Kirigami.Units.gridUnit
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Heading { text: "Behavior Settings"; level: 1; Layout.fillWidth: true; Layout.bottomMargin: Kirigami.Units.largeSpacing }

        Kirigami.Heading { text: "Startup & Playback"; level: 4; Layout.fillWidth: true }
        
        PlasmaComponents.CheckBox { id: autoplayCheckbox; text: "Start playing automatically on system login"; Layout.leftMargin: Kirigami.Units.largeSpacing }
        PlasmaComponents.CheckBox { id: autoLocalCheckbox; text: "Select closest local station on startup"; Layout.leftMargin: Kirigami.Units.largeSpacing }
        PlasmaComponents.CheckBox { id: resumePlaybackCheckbox; text: "Automatically resume playback if active when last closed"; Layout.leftMargin: Kirigami.Units.largeSpacing }
        PlasmaComponents.CheckBox { id: pauseOnBtDisconnectCheckbox; text: "Pause playback when active audio device disconnects"; Layout.leftMargin: Kirigami.Units.largeSpacing }
        PlasmaComponents.CheckBox { id: inhibitSleepCheckbox; text: "Prevent system sleep while playing"; Layout.leftMargin: Kirigami.Units.largeSpacing }
        PlasmaComponents.CheckBox { id: normalizeLoudnessCheckbox; text: "Normalize loudness across stations"; Layout.leftMargin: Kirigami.Units.largeSpacing }
        PlasmaComponents.CheckBox {
            id: loudnessAutoCheckbox
            text: "Measure levels automatically"
            enabled: normalizeLoudnessCheckbox.checked
            Layout.leftMargin: Kirigami.Units.largeSpacing
            PlasmaComponents.ToolTip { text: "When off, the per-station adjustments in the Stations tab become editable and are never overwritten." }
        }

        Kirigami.Separator { Layout.fillWidth: true; Layout.topMargin: Kirigami.Units.largeSpacing; Layout.bottomMargin: Kirigami.Units.largeSpacing }

        Kirigami.Heading { text: "Audio Output Priority"; level: 4; Layout.fillWidth: true }
        PlasmaComponents.Label {
            text: "Patron Radio will always use the available device that is highest in this list. Revert to system default by moving everything down."
            opacity: 0.7; font.pointSize: Kirigami.Theme.smallFont.pointSize; wrapMode: Text.WordWrap; Layout.fillWidth: true
        }

        ScrollView {
            Layout.fillWidth: true; Layout.preferredHeight: Kirigami.Units.gridUnit * 6; Layout.leftMargin: Kirigami.Units.largeSpacing
            ListView {
                id: priorityView; model: priorityModel; clip: true; spacing: 2
                delegate: ItemDelegate {
                    width: priorityView.width; height: Kirigami.Units.gridUnit * 2
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 4; anchors.rightMargin: 4
                        Kirigami.Icon { source: "audio-card"; width: 16; height: 16; opacity: model.isOnline ? 1.0 : 0.3 }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 0
                            PlasmaComponents.Label { text: model.name; elide: Text.ElideRight; Layout.fillWidth: true; opacity: model.isOnline ? 1.0 : 0.5 }
                            PlasmaComponents.Label { text: model.deviceId; font.pointSize: Kirigami.Theme.smallFont.pointSize * 0.8; opacity: 0.3; elide: Text.ElideRight; Layout.fillWidth: true }
                        }
                        RowLayout {
                            spacing: 0
                            PlasmaComponents.Button { icon.name: "arrow-up"; flat: true; enabled: index > 0; onClicked: movePriority(index, index - 1) }
                            PlasmaComponents.Button { icon.name: "arrow-down"; flat: true; enabled: index < priorityModel.count - 1; onClicked: movePriority(index, index + 1) }
                            PlasmaComponents.Button { icon.name: "edit-delete"; flat: true; onClicked: { priorityModel.remove(index); savePriority() } }
                        }
                    }
                }
            }
        }

        Kirigami.Separator { Layout.fillWidth: true; Layout.topMargin: Kirigami.Units.largeSpacing; Layout.bottomMargin: Kirigami.Units.largeSpacing }

        Kirigami.Heading { text: "Bluetooth Autoplay Triggers"; level: 4; Layout.fillWidth: true }
        PlasmaComponents.Label {
            text: "Check devices that should automatically trigger the 'Play' command when they connect."
            opacity: 0.7; font.pointSize: Kirigami.Theme.smallFont.pointSize; wrapMode: Text.WordWrap; Layout.fillWidth: true
        }

        ScrollView {
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.leftMargin: Kirigami.Units.largeSpacing
            ListView {
                id: autoplayView; model: autoplayModel; clip: true; spacing: 2
                delegate: PlasmaComponents.CheckBox {
                    text: model.name + " (" + model.address + ")"
                    checked: model.isChecked
                    onToggled: { autoplayModel.setProperty(index, "isChecked", checked); saveAutoplay() }
                }
            }
        }
        
    }
}
