import QtQuick
import org.kde.plasma.plasmoid
import org.kde.bluezqt as BluezQt

import "../imports/com/signal11/patronradio" as RadioBackendModule

Item {
    id: audioRouter

    property var btManager: BluezQt.Manager
    property var connectedBtDevices: ({})
    property string activeAudioDeviceId: ""
    property bool isRouting: false
    property bool manualOverrideActive: false

    signal routingChanged()

    function applyBestAudioRouting() {
        if (manualOverrideActive) {
            var systemOutputs = RadioBackendModule.RadioBackend.availableOutputs;
            var found = false;
            for (var i = 0; i < systemOutputs.length; i++) {
                if (systemOutputs[i].id === activeAudioDeviceId) {
                    found = true; break;
                }
            }
            if (found) {
                isRouting = false;
                return;
            } else {
                manualOverrideActive = false;
            }
        }

        var priorityList = [];
        try {
            var parsed = JSON.parse(Plasmoid.configuration.outputPriorityDevices || "[]");
            priorityList = parsed.map(function(item) { return typeof item === 'string' ? item : item.id; });
        } catch(e) {}

        var systemOutputs = RadioBackendModule.RadioBackend.availableOutputs;
        var targetDevice = null;
        for (var i = 0; i < priorityList.length; i++) {
            var prefId = priorityList[i];
            for (var j = 0; j < systemOutputs.length; j++) {
                if (systemOutputs[j].id === prefId) { targetDevice = systemOutputs[j]; break; }
            }
            if (targetDevice) break;
        }

        if (targetDevice) {
            if (activeAudioDeviceId !== targetDevice.id) {
                RadioBackendModule.RadioBackend.setAudioOutput(targetDevice.id);
                activeAudioDeviceId = targetDevice.id;
            }
        } else {
            if (activeAudioDeviceId !== "") {
                RadioBackendModule.RadioBackend.resetAudioOutput();
                activeAudioDeviceId = "";
            }
        }

        if (root.userRequestedPlayback && root.playbackState !== root.statePlaying && root.playbackState !== root.stateBroken) {
            root.logPlayTrigger("routing auto-resume (output change)");
            RadioBackendModule.RadioBackend.play();
        }

        isRouting = false;
    }

    Timer {
        id: btRoutingTimer
        interval: 500
        repeat: false
        onTriggered: {
            audioRouter.applyBestAudioRouting();
            audioRouter.routingChanged();
        }
    }

    Connections {
        target: audioRouter.btManager
        function onDeviceChanged(device) {
            if (!device) return;
            var addr = device.address;
            var isConnected = device.connected;
            var wasConnected = !!audioRouter.connectedBtDevices[addr];
            audioRouter.connectedBtDevices[addr] = isConnected;

            if (isConnected && !wasConnected) {
                audioRouter.isRouting = true;
                var autoplayList = [];
                try {
                    var parsed = JSON.parse(Plasmoid.configuration.autoplayBluetoothDevices || "[]");
                    autoplayList = parsed.map(function(item) { return typeof item === 'string' ? item : item.address; });
                } catch(e) {}
                if (autoplayList.indexOf(addr) !== -1) {
                    root.userRequestedPlayback = true;
                    if (root.playbackState === root.stateStopped) root.playStation(root.currentStationIndex, "bluetooth autoplay (" + addr + ")");
                }
                btRoutingTimer.restart();
            }

            if (!isConnected && wasConnected) {
                var normalizedMac = addr.toLowerCase().replace(/:/g, "_");
                if (audioRouter.activeAudioDeviceId.toLowerCase().indexOf(normalizedMac) !== -1) {
                    audioRouter.isRouting = true;
                    if (Plasmoid.configuration.pauseOnBtDisconnect) {
                        root.userRequestedPlayback = false;
                        RadioBackendModule.RadioBackend.stop();
                        root.playbackState = root.stateStopped;
                    }
                    audioRouter.activeAudioDeviceId = "";
                    if (audioRouter.manualOverrideActive) audioRouter.manualOverrideActive = false;
                }
                btRoutingTimer.restart();
            }
        }
    }

    Connections {
        target: RadioBackendModule.RadioBackend
        function onAvailableOutputsChanged() {
            audioRouter.isRouting = true;
            btRoutingTimer.restart();
            audioRouter.routingChanged();
        }
    }
}
