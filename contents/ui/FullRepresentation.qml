import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import org.kde.plasma.extras as PlasmaExtras

PlasmaExtras.Representation {
    id: fullRoot

    Layout.minimumWidth: Kirigami.Units.gridUnit * 18
    Layout.minimumHeight: Kirigami.Units.gridUnit * 22
    Layout.preferredWidth: Kirigami.Units.gridUnit * 20
    Layout.preferredHeight: Kirigami.Units.gridUnit * 26

    header: PlasmaExtras.PlasmoidHeading {
        RowLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            // Donate — a heart styled like the other header controls (positive
            // colour to read as "support"), leading the header.
            PlasmaComponents.ToolButton {
                visible: root.currentStationDonate !== ""
                icon.name: "help-donate"
                icon.color: Kirigami.Theme.positiveTextColor
                activeFocusOnTab: visible
                hoverEnabled: true
                Layout.alignment: Qt.AlignVCenter
                onClicked: {
                    var url = root.currentStationDonate;
                    if (url !== "") {
                        url += url.indexOf("?") > -1 ? "&" : "?";
                        url += "source=plasma_radio";
                        root.openExternalUrl(url);
                    }
                }
                PlasmaComponents.ToolTip {
                    text: "Support " + root.currentStationName
                    visible: parent.hovered || parent.activeFocus
                }
            }

            // Station name + now playing
            ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 0

                PlasmaComponents.Label {
                    text: root.currentStationName
                    textFormat: Text.PlainText
                    font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.4
                    font.weight: Font.Bold
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }

                PlasmaComponents.Label {
                    text: root.currentTrack !== "" ? root.currentTrack : root.currentStationCity
                    textFormat: Text.PlainText
                    opacity: 0.7
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    font.italic: root.currentTrack !== ""
                }
            }
            
            // Right Side: transport + overflow
            RowLayout {
                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                spacing: Kirigami.Units.smallSpacing

                // Transport — same size as the overflow button (consistent), but
                // honest about all four states: play / stop / buffering (spinner) /
                // broken (fix). Fixed-size wrapper so the spinner swap doesn't reflow.
                Item {
                    id: transport
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: overflowBtn.implicitWidth
                    Layout.preferredHeight: overflowBtn.implicitHeight

                    PlasmaComponents.ToolButton {
                        anchors.fill: parent
                        // Hide the icon while buffering; the spinner takes its place.
                        icon.name: root.isBuffering ? ""
                                 : (root.isBroken ? "tools-wizard"
                                 : (root.isPlaying ? "media-playback-stop" : "media-playback-start"))
                        activeFocusOnTab: true
                        hoverEnabled: true
                        onClicked: { if (root.isBroken) root.fixCurrentStream(); else root.togglePlay(); }
                        PlasmaComponents.ToolTip {
                            text: root.isBroken ? "Find a working stream"
                                : (root.isBuffering ? "Buffering — click to stop"
                                : (root.isPlaying ? "Stop" : "Play"))
                            visible: parent.hovered || parent.activeFocus
                        }
                    }
                    PlasmaComponents.BusyIndicator {
                        anchors.centerIn: parent
                        width: Kirigami.Units.iconSizes.smallMedium
                        height: Kirigami.Units.iconSizes.smallMedium
                        visible: root.isBuffering
                        running: visible
                    }
                }

                // Overflow menu — secondary, default size. Same actions as the panel
                // right-click menu (both built from contextActions.actionList).
                // it stays in sync (both are built from contextActions.actionList).
                PlasmaComponents.ToolButton {
                    id: overflowBtn
                    icon.name: "overflow-menu"
                    activeFocusOnTab: true
                    onClicked: { contextActions.update(); actionsMenu.rebuild(); actionsMenu.popup() }
                    hoverEnabled: true
                    PlasmaComponents.ToolTip {
                        text: "More actions"
                        visible: parent.hovered || parent.activeFocus
                    }

                    Menu {
                        id: actionsMenu
                        // Grab keyboard focus while open so arrow keys navigate the
                        // menu instead of leaking through to the list underneath.
                        focus: true
                        onClosed: stationList.forceActiveFocus()

                        Component {
                            id: actionItemComp
                            MenuItem {
                                property var actionRef
                                text: actionRef ? actionRef.text : ""
                                icon.name: (actionRef && actionRef.icon && actionRef.icon.name) ? actionRef.icon.name : ""
                                checkable: actionRef ? actionRef.checkable === true : false
                                checked: actionRef ? actionRef.checked === true : false
                                onTriggered: {
                                    if (!actionRef) return;
                                    if (actionRef.trigger) actionRef.trigger(); else actionRef.triggered();
                                }
                            }
                        }
                        Component {
                            id: configItemComp
                            MenuItem {
                                text: "Configure Patron Radio…"
                                icon.name: "configure"
                                onTriggered: {
                                    var a = (typeof Plasmoid.internalAction === "function") ? Plasmoid.internalAction("configure") : null;
                                    if (a) a.trigger();
                                }
                            }
                        }
                        Component { id: separatorComp; MenuSeparator {} }

                        // Rebuild from the shared action list, mirroring the right-click
                        // menu's separators, then append Configure (overflow-only -- the
                        // panel menu already gets Configure from the shell).
                        function rebuild() {
                            while (count > 0) { var old = itemAt(0); removeItem(old); old.destroy(); }
                            var list = contextActions.actionList || [];
                            var lastWasSep = true; // suppress leading separators
                            for (var i = 0; i < list.length; i++) {
                                var a = list[i];
                                if (!a) continue;
                                if (a.isSeparator) {
                                    if (!lastWasSep) { addItem(separatorComp.createObject(actionsMenu)); lastWasSep = true; }
                                } else {
                                    addItem(actionItemComp.createObject(actionsMenu, { actionRef: a }));
                                    lastWasSep = false;
                                }
                            }
                            var hasConfig = (typeof Plasmoid.internalAction === "function") && Plasmoid.internalAction("configure");
                            if (hasConfig) {
                                if (!lastWasSep) addItem(separatorComp.createObject(actionsMenu));
                                addItem(configItemComp.createObject(actionsMenu));
                                lastWasSep = false;
                            }
                            if (lastWasSep && count > 0) { var last = itemAt(count - 1); removeItem(last); last.destroy(); }
                        }
                    }
                }
            }
        }
    }

    // Re-focus the list each time the popup opens (the component may be cached
    // across opens, so Component.onCompleted alone isn't enough for the shortcut).
    Connections {
        target: root
        function onExpandedChanged() {
            if (root.expanded) {
                stationList.currentIndex = root.currentStationIndex + 1;
                stationList.forceActiveFocus();
            }
        }
    }

    // Main Content Area: recently-played strip + station list
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Recently played — the live "playlist". Shows previous tracks (the
        // current one is already in the header); collapses when there's no data.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing / 2
            visible: trackHistory.count > 1

            RowLayout {
                Layout.fillWidth: true
                PlasmaComponents.Label {
                    text: "Recently played"
                    font.weight: Font.Bold
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    opacity: 0.8
                    Layout.fillWidth: true
                }
                PlasmaComponents.ToolButton {
                    visible: root.currentStationWebsite !== ""
                    text: "Playlist"
                    icon.name: "link"
                    flat: true
                    display: AbstractButton.TextBesideIcon
                    onClicked: {
                        var url = root.currentStationWebsite;
                        url += url.indexOf("?") > -1 ? "&" : "?";
                        url += "source=plasma_radio";
                        root.openExternalUrl(url);
                    }
                    PlasmaComponents.ToolTip { text: "Open the station's playlist page"; visible: parent.hovered }
                }
            }

            Repeater {
                model: trackHistory
                delegate: RowLayout {
                    visible: index >= 1 && index <= 3
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing
                    PlasmaComponents.Label {
                        text: root.relTime(model.at)
                        opacity: 0.5
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 1.6
                        horizontalAlignment: Text.AlignRight
                    }
                    PlasmaComponents.Label {
                        text: model.title
                        textFormat: Text.PlainText
                        opacity: 0.85
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    }
                }
            }

            Kirigami.Separator { Layout.fillWidth: true; Layout.topMargin: Kirigami.Units.largeSpacing }
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            
            ListView {
                id: stationList
                model: stationModel.count + 1
                clip: true

                // Keyboard navigation (e.g. when the popup is opened via shortcut).
                focus: true
                activeFocusOnTab: true
                keyNavigationEnabled: true
                highlightMoveDuration: 0
                Component.onCompleted: {
                    // Start on the current station (index 0 is "Play Nearest").
                    currentIndex = root.currentStationIndex + 1;
                    forceActiveFocus();
                }

                function activateCurrent() {
                    if (currentIndex <= 0) root.playClosestStation();
                    else root.playStation(currentIndex - 1);
                    root.expanded = false;
                }
                Keys.onReturnPressed: activateCurrent()
                Keys.onEnterPressed: activateCurrent()
                Keys.onSpacePressed: activateCurrent()
                // Context menu via the Menu key / Shift+F10 convention.
                Keys.onMenuPressed: { contextActions.update(); actionsMenu.rebuild(); actionsMenu.popup() }
                Keys.onPressed: (event) => {
                    if (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier)) {
                        contextActions.update();
                        actionsMenu.rebuild();
                        actionsMenu.popup();
                        event.accepted = true;
                    }
                }

                delegate: PlasmaComponents.ItemDelegate {
                    width: stationList.width - Kirigami.Units.smallSpacing
                    highlighted: ListView.isCurrentItem
                    // Don't make every row a Tab stop — arrow keys navigate the list;
                    // Tab should jump straight to the header buttons.
                    activeFocusOnTab: false

                    property bool isAutoLocalItem: index === 0
                    property int actualStationIndex: index - 1
                    property bool isCurrentStation: !isAutoLocalItem && root.currentStationIndex === actualStationIndex

                    contentItem: RowLayout {
                        spacing: Kirigami.Units.largeSpacing + Kirigami.Units.smallSpacing

                        Item {
                            Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                            Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                            opacity: 0.8

                            property string currentIconType: isAutoLocalItem ? "mark-location" : (stationModel.get(actualStationIndex).icon || "emblem-music-symbolic")

                            Kirigami.Icon {
                                anchors.fill: parent
                                source: parent.currentIconType !== "mixed-composite" ? parent.currentIconType : ""
                                visible: parent.currentIconType !== "mixed-composite"
                            }

                            Kirigami.Icon {
                                width: parent.width * 0.55
                                height: parent.height * 0.55
                                anchors.bottom: parent.bottom
                                anchors.left: parent.left
                                source: "mic-on-symbolic"
                                visible: parent.currentIconType === "mixed-composite"
                            }

                            Kirigami.Icon {
                                width: parent.width * 0.55
                                height: parent.height * 0.55
                                anchors.top: parent.top
                                anchors.right: parent.right
                                source: "emblem-music-symbolic"
                                visible: parent.currentIconType === "mixed-composite"
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            PlasmaComponents.Label {
                                text: isAutoLocalItem ? (root.isLocating ? "Locating..." : "Play Nearest Station") : stationModel.get(actualStationIndex).name
                                textFormat: Text.PlainText
                                font.weight: isCurrentStation ? Font.Bold : Font.Normal
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }

                            PlasmaComponents.Label {
                                visible: !isAutoLocalItem
                                text: !isAutoLocalItem ? stationModel.get(actualStationIndex).city : ""
                                textFormat: Text.PlainText
                                opacity: 0.7
                                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }
                        }

                        Kirigami.Icon {
                            visible: isCurrentStation && root.isPlaying
                            source: "media-playback-start"
                            Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                            Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                            color: Kirigami.Theme.positiveTextColor
                        }
                    }

                    function activate() {
                        if (isAutoLocalItem) {
                            root.playClosestStation();
                        } else {
                            root.playStation(actualStationIndex);
                        }
                        root.expanded = false;
                    }
                    onClicked: activate()
                    // AbstractButton activates on Space but ignores Return/Enter, so
                    // wire those up explicitly for keyboard "select".
                    Keys.onReturnPressed: (event) => { activate(); event.accepted = true; }
                    Keys.onEnterPressed: (event) => { activate(); event.accepted = true; }

                    PlasmaComponents.ToolTip {
                        visible: isAutoLocalItem && parent.hovered
                        text: "Uses your IP address to find and play the closest configured radio station."
                    }
                }
            }
        }
    }
}
