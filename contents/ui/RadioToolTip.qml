import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

Item {
    id: tooltipRoot
    
    // Bind the size to the layout's implicit size so Plasma knows how big it is
    implicitWidth: layout.implicitWidth
    implicitHeight: layout.implicitHeight

    ColumnLayout {
        id: layout
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            spacing: Kirigami.Units.smallSpacing
            
            Kirigami.Icon {
                source: root.currentStationIcon
                Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                visible: root.currentStationIcon !== ""
            }

            ColumnLayout {
                spacing: 0
                
                PlasmaComponents.Label {
                    text: root.isLocating ? i18n("Locating Station...")
                        : (root.isFixing ? i18n("Finding new stream...")
                        : (root.isPlaying ? i18nc("@info:tooltip, %1 is a station name", "Playing: %1", root.currentStationName)
                        : (root.isBroken ? i18n("Stream Offline")
                        : i18n("Patron Radio"))))
                    textFormat: Text.PlainText
                    font.weight: Font.Bold
                    Layout.fillWidth: true
                }
                
                PlasmaComponents.Label {
                    text: {
                        var subText = "";
                        if (root.isLocating) {
                            subText = i18n("Finding closest local station...");
                        } else if (root.isFixing) {
                            subText = i18n("Searching radio-browser.info for a working stream...");
                        } else if (root.isBroken) {
                            subText = root.errorMessage
                                ? i18nc("@info:tooltip, %1 station name, %2 error detail", "%1 stream is currently unavailable. (%2)", root.currentStationName, root.errorMessage)
                                : i18nc("@info:tooltip, %1 is a station name", "%1 stream is currently unavailable.", root.currentStationName);
                            subText += " " + i18nc("@info:tooltip", "Click 'Fix' to search for a new URL.");
                        } else {
                            // %1 carries "<station>" or "<station> from <city>".
                            var where = root.currentStationCity !== ""
                                ? i18nc("@info:tooltip, %1 station name, %2 city", "%1 from %2", root.currentStationName, root.currentStationCity)
                                : root.currentStationName;
                            subText = root.isPlaying ? i18nc("@info:tooltip, %1 is the station/city phrase", "Playing %1", where)
                                    : (root.isBuffering ? i18nc("@info:tooltip, %1 is the station/city phrase", "Buffering %1", where)
                                    : i18nc("@info:tooltip, %1 is the station/city phrase", "Stopped %1", where));
                            if (root.currentTrack !== "") {
                                subText += "\n" + i18nc("@info:tooltip, %1 is the track title", "Now Playing: %1", root.currentTrack);
                            }
                            var techInfo = [];
                            if (root.streamCodec !== "") techInfo.push(root.streamCodec);
                            if (root.streamBitrate !== "") techInfo.push(root.streamBitrate);
                            if (techInfo.length > 0) {
                                subText += "\n[" + techInfo.join(" @ ") + "]";
                            }
                        }
                        return subText;
                    }
                    textFormat: Text.PlainText
                    opacity: 0.7
                    Layout.fillWidth: true
                }
            }
        }
        
        Kirigami.Separator {
            Layout.fillWidth: true
        }
        
        PlasmaComponents.Label {
            text: i18n("Click to open menu for station details, website, and donation options.")
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            opacity: 0.7
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
        }
    }
}