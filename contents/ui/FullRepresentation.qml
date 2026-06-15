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

            // Left Side: Information
            ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                Layout.leftMargin: 1
                spacing: 0
                
                PlasmaComponents.Label {
                    text: root.currentStationName
                    textFormat: Text.PlainText
                    font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.5
                    font.weight: Font.Bold
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                }

                PlasmaComponents.Label {
                    text: root.currentTrack !== "" ? root.currentTrack : root.currentStationCity
                    textFormat: Text.PlainText
                    opacity: 0.7
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    font.italic: root.currentTrack !== ""
                }
            }
            
            // Right Side: All Actions
            RowLayout {
                Layout.alignment: Qt.AlignRight | Qt.AlignTop
                Layout.topMargin: Kirigami.Units.tinySpacing
                spacing: Kirigami.Units.smallSpacing
                
                PlasmaComponents.ToolButton {
                    icon.name: root.isPlaying ? "media-playback-stop" : "media-playback-start"
                    onClicked: root.togglePlay()
                    hoverEnabled: true
                    activeFocusOnTab: true
                    PlasmaComponents.ToolTip {
                        text: root.isPlaying ? "Stop Playback" : "Start Playback"
                        visible: parent.hovered || parent.activeFocus
                    }
                }
                
                PlasmaComponents.ToolButton {
                    icon.name: "help-donate"
                    icon.color: Kirigami.Theme.positiveTextColor
                    visible: root.currentStationDonate !== ""
                    activeFocusOnTab: visible
                    onClicked: {
                        var url = root.currentStationDonate;
                        if (url !== "") {
                            url += url.indexOf("?") > -1 ? "&" : "?";
                            url += "source=plasma_radio";
                            root.openExternalUrl(url);
                        }
                    }
                    hoverEnabled: true
                    PlasmaComponents.ToolTip {
                        text: "Donate to Station"
                        visible: parent.hovered || parent.activeFocus
                    }
                }
                
                PlasmaComponents.ToolButton {
                    icon.name: "view-media-playlist"
                    visible: root.currentStationWebsite !== ""
                    activeFocusOnTab: visible
                    onClicked: {
                        var url = root.currentStationWebsite;
                        if (url !== "") {
                            url += url.indexOf("?") > -1 ? "&" : "?";
                            url += "source=plasma_radio";
                            root.openExternalUrl(url);
                        }
                    }
                    hoverEnabled: true
                    PlasmaComponents.ToolTip {
                        text: "Station Website / Playlist"
                        visible: parent.hovered || parent.activeFocus
                    }
                }

                // Overflow menu — same actions as the panel right-click menu, so
                // it stays in sync (both are built from contextActions.actionList).
                PlasmaComponents.ToolButton {
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

    // Main Content Area: Scrollable List
    Item {
        anchors.fill: parent

        ScrollView {
            anchors.fill: parent
            
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
