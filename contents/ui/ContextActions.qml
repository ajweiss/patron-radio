import QtQuick
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore

import "../imports/com/signal11/patronradio" as RadioBackendModule

Item {
    id: contextActions

    Item {
        id: actionFactory
        function createAction() { return actionComponent.createObject(actionFactory); }
        function createSeparator() {
            var a = actionComponent.createObject(actionFactory);
            a.isSeparator = true;
            return a;
        }
        Component {
            id: actionComponent
            PlasmaCore.Action {}
        }
        function clear() {
            for (var i = children.length - 1; i >= 0; i--) {
                children[i].destroy();
            }
        }
    }

    function update() {
        actionFactory.clear();
        var actions = [];

        // 1. Playback / Fix Actions
        var playbackAction = actionFactory.createAction();
        playbackAction.text = root.isBroken ? "Fix Broken Stream" : (root.isPlaying ? "Stop Playback" : "Start Playback");
        playbackAction.icon.name = root.isBroken ? "tools-wizard" : (root.isPlaying ? "media-playback-stop" : "media-playback-start");
        playbackAction.triggered.connect(function() {
            if (root.isBroken) root.fixCurrentStream();
            else root.togglePlay();
        });
        actions.push(playbackAction);

        actions.push(actionFactory.createSeparator());

        // 2. Station Links
        if (root.currentStationDonate !== "") {
            var donateAction = actionFactory.createAction();
            donateAction.text = "Support this Station (Donate)";
            donateAction.icon.name = "help-donate";
            donateAction.triggered.connect(function() { Qt.openUrlExternally(root.currentStationDonate); });
            actions.push(donateAction);
        }

        if (root.currentStationWebsite !== "") {
            var webAction = actionFactory.createAction();
            webAction.text = "Station Website / Playlist";
            webAction.icon.name = "view-media-playlist";
            webAction.triggered.connect(function() { Qt.openUrlExternally(root.currentStationWebsite); });
            actions.push(webAction);
        }

        // 3. Audio Routing Section
        actions.push(actionFactory.createSeparator());

        var autoRouteAction = actionFactory.createAction();
        autoRouteAction.text = "Automatic Routing (Priority List)";
        autoRouteAction.icon.name = "audio-backend-pulse";
        autoRouteAction.checkable = true;
        autoRouteAction.checked = !audioRouter.manualOverrideActive;
        autoRouteAction.triggered.connect(function() {
            audioRouter.manualOverrideActive = false;
            RadioBackendModule.RadioBackend.resetAudioOutput();
            audioRouter.applyBestAudioRouting();
            contextActions.update();
        });
        actions.push(autoRouteAction);

        var systemOutputs = RadioBackendModule.RadioBackend.availableOutputs;
        for (var i = 0; i < systemOutputs.length; i++) {
            var dev = systemOutputs[i];
            var isBluetooth = dev.id.indexOf("bluez") !== -1;
            var isActive = dev.id === audioRouter.activeAudioDeviceId;

            if (isBluetooth || isActive) {
                var routeAction = (function(dId, dName, isBT) {
                    var a = actionFactory.createAction();
                    a.text = dName;
                    a.icon.name = isBT ? "network-bluetooth" : "audio-card";
                    a.checkable = true;
                    a.checked = (audioRouter.manualOverrideActive && audioRouter.activeAudioDeviceId === dId);
                    a.triggered.connect(function() {
                        audioRouter.manualOverrideActive = true;
                        audioRouter.activeAudioDeviceId = dId;
                        RadioBackendModule.RadioBackend.setAudioOutput(dId);
                        contextActions.update();
                    });
                    return a;
                })(dev.id, dev.name, isBluetooth);
                actions.push(routeAction);
            }
        }

        actions.push(actionFactory.createSeparator());
        Plasmoid.contextualActions = actions;
    }
}
