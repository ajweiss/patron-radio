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
                    text: root.isLocating ? "Locating Station..." : (root.isFixing ? "Finding new stream..." : (root.isPlaying ? "Playing: " + root.currentStationName : (root.isBroken ? "Stream Offline" : "Plasma Radio")))
                    font.weight: Font.Bold
                    Layout.fillWidth: true
                }
                
                PlasmaComponents.Label {
                    text: {
                        var subText = "";
                        if (root.isLocating) {
                            subText = "Finding closest local station...";
                        } else if (root.isFixing) {
                            subText = "Searching radio-browser.info for a working stream...";
                        } else if (root.isBroken) {
                            subText = root.currentStationName + " stream is currently unavailable.";
                            if (root.errorMessage) subText += " (" + root.errorMessage + ")";
                            subText += " Click 'Fix' to search for a new URL.";
                        } else {
                            var status = root.isPlaying ? "Playing" : (root.isBuffering ? "Buffering" : "Stopped");
                            var info = root.currentStationName;
                            if (root.currentStationCity !== "") info += " from " + root.currentStationCity;
                            subText = status + " " + info;
                            if (root.currentTrack !== "") {
                                subText += "\nNow Playing: " + root.currentTrack;
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
                    opacity: 0.7
                    Layout.fillWidth: true
                }
            }
        }
        
        Kirigami.Separator {
            Layout.fillWidth: true
        }
        
        PlasmaComponents.Label {
            text: "Click to open menu for station details, website, and donation options."
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            opacity: 0.7
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
        }
    }
}