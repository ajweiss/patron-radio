import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

Item {
    id: compactRoot
    
    // 1. Configuration & Sizing Modes
    readonly property int widthMode: Plasmoid.configuration.widthMode // 0=Fixed, 1=Auto(City), 2=Auto(Everything)
    
    // Width components - Minimal padding for a snug fit
    readonly property real horizontalPadding: Kirigami.Units.smallSpacing
    
    // Explicitly measure text widths using contentWidth.
    // +2px buffer compensates for sub-pixel rounding that otherwise clips the last glyph.
    readonly property real measuredNameWidth: Math.ceil(statePrefixLabel.contentWidth + (Kirigami.Units.smallSpacing / 2) + stationNameLabel.contentWidth) + 2
    readonly property real measuredCityWidth: Math.ceil(cityWidthHelper.contentWidth) + 2
    readonly property real measuredTrackWidth: Math.ceil(subtitleLabel.contentWidth) + 2

    readonly property real contentTargetWidth: {
        if (widthMode === 0) return (Kirigami.Units.gridUnit * Plasmoid.configuration.compactWidth);
        var baseFit = Math.max(Kirigami.Units.gridUnit * 2, measuredNameWidth, measuredCityWidth);
        if (widthMode === 1) return baseFit;
        return Math.max(baseFit, measuredTrackWidth);
    }

    // Root size constraints
    readonly property real totalWidth: contentTargetWidth + (compactRoot.horizontalPadding * 2)
    
    width: totalWidth
    height: parent.height
    clip: true 
    
    Layout.preferredWidth: totalWidth
    Layout.maximumWidth: totalWidth
    Layout.minimumWidth: (widthMode === 0) ? totalWidth : Kirigami.Units.gridUnit * 2
    Layout.minimumHeight: Kirigami.Units.iconSizes.small

    property int subtitleDisplayState: 0 // 0 = City, 1 = Track
    
    Timer {
        id: alternateSubtitleTimer
        interval: 15000
        repeat: true
        running: Plasmoid.configuration.compactSubtitleMode === 2
        onTriggered: compactRoot.subtitleDisplayState = (compactRoot.subtitleDisplayState + 1) % 2
    }

    readonly property string subtitleText: {
        var mode = Plasmoid.configuration.compactSubtitleMode;
        if (mode === 0) return root.currentStationCity;
        if (mode === 1) return root.currentTrack || root.currentStationCity;
        return compactRoot.subtitleDisplayState === 0 ? root.currentStationCity : (root.currentTrack || root.currentStationCity);
    }

    PlasmaComponents.Label {
        id: cityWidthHelper
        text: root.currentStationCity
        textFormat: Text.PlainText
        visible: false
        font.pointSize: Kirigami.Theme.smallFont.pointSize * 0.9
        font.weight: Font.Normal
    }

    // Marquee logic
    readonly property bool shouldMarquee: (subtitleLabel.contentWidth > (subtitleContainer.width + 2))

    function resetMarquee() {
        marqueeAnimation.stop();
        subtitleLabel.x = 0;
        if (shouldMarquee) {
            marqueeAnimation.restart();
        }
    }

    onSubtitleDisplayStateChanged: resetMarquee()
    
    Connections {
        target: root
        function onCurrentTrackChanged() {
            resetMarquee();
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        onClicked: (mouse) => {
            if (mouse.button === Qt.LeftButton) root.expanded = !root.expanded
            else if (mouse.button === Qt.MiddleButton) root.togglePlay()
        }
    }

    // Centered Column for Station and Subtitle
    ColumnLayout {
        id: mainColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: compactRoot.horizontalPadding
        anchors.rightMargin: compactRoot.horizontalPadding
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0
        
        RowLayout {
            id: stationNameRow
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing / 2

            PlasmaComponents.Label {
                id: statePrefixLabel
                text: root.isBroken ? "⚠" : (root.isBuffering ? "↻" : (root.isPlaying ? "▶" : "■"))
                font.weight: Font.Bold
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                transform: Translate { y: -1 }
            }
            PlasmaComponents.Label {
                id: stationNameLabel
                text: root.currentStationName
                textFormat: Text.PlainText
                font.weight: Font.Bold
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                Layout.fillWidth: true
                elide: (widthMode === 0) ? Text.ElideRight : Text.ElideNone
            }
        }
        
        Item {
            id: subtitleContainer
            height: subtitleLabel.implicitHeight
            Layout.fillWidth: true
            clip: true
            
            onWidthChanged: resetMarquee()

            PlasmaComponents.Label {
                id: subtitleLabel
                text: compactRoot.subtitleText
                textFormat: Text.PlainText
                opacity: 0.7
                font.pointSize: Kirigami.Theme.smallFont.pointSize * 0.9
                
                // Use contentWidth to ensure pixel-perfect marquee calculations
                width: contentWidth
                elide: Text.ElideNone
                wrapMode: Text.NoWrap

                SequentialAnimation on x {
                    id: marqueeAnimation
                    running: compactRoot.shouldMarquee
                    loops: Animation.Infinite
                    
                    PauseAnimation { duration: 2000 }
                    NumberAnimation {
                        from: 0
                        to: -(subtitleLabel.width - subtitleContainer.width + 4)
                        duration: Math.max(1500, (subtitleLabel.width - subtitleContainer.width) * 20)
                        easing.type: Easing.Linear
                    }
                    PauseAnimation { duration: 2000 }
                    NumberAnimation {
                        to: 0
                        duration: 600
                        easing.type: Easing.InOutQuad
                    }
                }
            }
        }
    }
}
