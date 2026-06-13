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
                    font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.5
                    font.weight: Font.Bold
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                }
                
                PlasmaComponents.Label {
                    text: root.currentTrack !== "" ? root.currentTrack : root.currentStationCity
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
                    PlasmaComponents.ToolTip {
                        text: root.isPlaying ? "Stop Playback" : "Start Playback"
                        visible: parent.hovered
                    }
                }
                
                PlasmaComponents.ToolButton {
                    icon.name: "help-donate"
                    icon.color: Kirigami.Theme.positiveTextColor
                    visible: root.currentStationDonate !== ""
                    onClicked: {
                        var url = root.currentStationDonate;
                        if (url !== "") {
                            url += url.indexOf("?") > -1 ? "&" : "?";
                            url += "source=plasma_radio";
                            Qt.openUrlExternally(url);
                        }
                    }
                    hoverEnabled: true
                    PlasmaComponents.ToolTip {
                        text: "Donate to Station"
                        visible: parent.hovered
                    }
                }
                
                PlasmaComponents.ToolButton {
                    icon.name: "view-media-playlist"
                    visible: root.currentStationWebsite !== ""
                    onClicked: {
                        var url = root.currentStationWebsite;
                        if (url !== "") {
                            url += url.indexOf("?") > -1 ? "&" : "?";
                            url += "source=plasma_radio";
                            Qt.openUrlExternally(url);
                        }
                    }
                    hoverEnabled: true
                    PlasmaComponents.ToolTip {
                        text: "Station Website / Playlist"
                        visible: parent.hovered
                    }
                }
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

                delegate: PlasmaComponents.ItemDelegate {
                    width: stationList.width - Kirigami.Units.smallSpacing

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
                                font.weight: isCurrentStation ? Font.Bold : Font.Normal
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }

                            PlasmaComponents.Label {
                                visible: !isAutoLocalItem
                                text: !isAutoLocalItem ? stationModel.get(actualStationIndex).city : ""
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

                    onClicked: {
                        if (isAutoLocalItem) {
                            root.playClosestStation();
                        } else {
                            root.playStation(actualStationIndex);
                        }
                        root.expanded = false;
                    }

                    PlasmaComponents.ToolTip {
                        visible: isAutoLocalItem && parent.hovered
                        text: "Uses your IP address to find and play the closest configured radio station."
                    }
                }
            }
        }
    }
}
