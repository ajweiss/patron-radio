import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents

Item {
    id: loudnessRoot
    Layout.fillWidth: true
    Layout.fillHeight: true

    property alias cfg_normalizeLoudness: normalizeCheckbox.checked
    property alias cfg_loudnessAuto: autoCheckbox.checked

    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: Kirigami.Units.largeSpacing + 3
        anchors.bottomMargin: Kirigami.Units.largeSpacing + 3
        anchors.leftMargin: Kirigami.Units.gridUnit
        anchors.rightMargin: Kirigami.Units.gridUnit
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Heading { text: "Loudness"; level: 1; Layout.fillWidth: true; Layout.bottomMargin: Kirigami.Units.largeSpacing }

        PlasmaComponents.Label {
            text: "Even out volume differences between stations (EBU R128), so switching isn't jarring."
            opacity: 0.7; font.pointSize: Kirigami.Theme.smallFont.pointSize; wrapMode: Text.WordWrap; Layout.fillWidth: true
        }

        PlasmaComponents.CheckBox {
            id: normalizeCheckbox
            text: "Normalize loudness across stations"
            Layout.topMargin: Kirigami.Units.largeSpacing
            Layout.leftMargin: Kirigami.Units.largeSpacing
        }
        PlasmaComponents.CheckBox {
            id: autoCheckbox
            text: "Measure levels automatically"
            enabled: normalizeCheckbox.checked
            Layout.leftMargin: Kirigami.Units.largeSpacing
        }
        PlasmaComponents.Label {
            text: "When off, per-station levels are editable in the Stations tab."
            opacity: 0.7; font.pointSize: Kirigami.Theme.smallFont.pointSize; wrapMode: Text.WordWrap
            Layout.fillWidth: true; Layout.leftMargin: Kirigami.Units.largeSpacing * 2
        }

        Item { Layout.fillHeight: true } // keep content top-aligned
    }
}
