import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents

Item {
    id: appearanceRoot
    Layout.fillWidth: true
    Layout.fillHeight: true

    property alias cfg_compactSubtitleMode: subtitleModeCombo.currentIndex
    property alias cfg_widthMode: widthModeCombo.currentIndex
    property alias cfg_compactWidth: widthSlider.value

    ColumnLayout {
        anchors.fill: parent
        
        // Precise padding to match system pages (approx 4mm V, 5mm H)
        anchors.topMargin: Kirigami.Units.largeSpacing + 3 // Refined vertical padding (largeSpacing + 3px)
        anchors.bottomMargin: Kirigami.Units.largeSpacing + 3
        anchors.leftMargin: Kirigami.Units.gridUnit // Correct horizontal padding
        anchors.rightMargin: Kirigami.Units.gridUnit
        
        spacing: Kirigami.Units.smallSpacing

        // --- Page Title ---
        Kirigami.Heading {
            text: "Appearance"
            level: 1 // Massive page title, matching 'About'
            Layout.fillWidth: true
            Layout.bottomMargin: Kirigami.Units.largeSpacing // Standard space below main title
        }

        // --- Taskbar Information Section ---
        Kirigami.Heading {
            text: "Taskbar Information"
            level: 4
            Layout.fillWidth: true
        }
        
        PlasmaComponents.Label {
            text: "Control what details are shown on the panel alongside the station name."
            opacity: 0.7
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
            Layout.bottomMargin: Kirigami.Units.smallSpacing
        }

        RowLayout {
            Layout.leftMargin: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.largeSpacing

            PlasmaComponents.Label {
                text: "Subtitle Display:"
            }

            PlasmaComponents.ComboBox {
                id: subtitleModeCombo
                model: ["Show Station City", "Show Stream Title", "Alternate City and Title"]
                Layout.preferredWidth: Kirigami.Units.gridUnit * 12
            }
        }

        Kirigami.Separator { Layout.fillWidth: true; Layout.topMargin: Kirigami.Units.largeSpacing; Layout.bottomMargin: Kirigami.Units.largeSpacing }

        // --- Taskbar Sizing Section ---
        Kirigami.Heading {
            text: "Taskbar Sizing"
            level: 4
            Layout.fillWidth: true
        }
        
        PlasmaComponents.Label {
            text: "Adjust how much horizontal space the widget occupies on your panel."
            opacity: 0.7
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
            Layout.bottomMargin: Kirigami.Units.smallSpacing
        }

        RowLayout {
            Layout.leftMargin: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.largeSpacing

            PlasmaComponents.Label {
                text: "Sizing Mode:"
            }

            PlasmaComponents.ComboBox {
                id: widthModeCombo
                model: ["Fixed Width", "Auto-fit Station & City", "Auto-fit Everything"]
                Layout.preferredWidth: Kirigami.Units.gridUnit * 12
            }
        }

        RowLayout {
            Layout.leftMargin: Kirigami.Units.largeSpacing
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            visible: widthModeCombo.currentIndex === 0
            
            PlasmaComponents.Label {
                text: "Fixed Width:"
            }

            PlasmaComponents.Slider {
                id: widthSlider
                from: 4
                to: 25
                stepSize: 1
                Layout.fillWidth: true
            }
            
            PlasmaComponents.Label {
                text: widthSlider.value + " units"
            }
        }
        
        Item { Layout.fillHeight: true } // Spacer pushes everything up
    }
}
