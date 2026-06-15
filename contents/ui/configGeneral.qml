import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents

import "../imports/com/signal11/patronradio" as RadioBackendModule

Item {
    id: configRoot
    Layout.fillWidth: true
    Layout.fillHeight: true

    property string cfg_stationsJson: ""
    property bool cfg_loudnessAuto: true

    readonly property real loudnessTarget: RadioBackendModule.RadioBackend.loudnessTarget

    // Attenuation (dB, <= 0) applied to a station given its measured loudness.
    // Mirrors RadioBackend::attenuationGainDb: attenuate only, clamp to -24 dB.
    function adjustmentDb(loud) {
        if (typeof loud !== "number" || isNaN(loud)) return NaN
        var g = loudnessTarget - loud
        if (g > 0) g = 0
        if (g < -24) g = -24
        return g
    }

    ListModel {
        id: internalModel
    }

    Component.onCompleted: {
        loadModel()
    }

    function loadModel() {
        internalModel.clear()
        try {
            var stations = JSON.parse(cfg_stationsJson || "[]")
            for (var i = 0; i < stations.length; i++) {
                var s = stations[i]
                // Ensure the 'loudness' role exists (ListModel fixes roles from row 0).
                if (typeof s.loudness !== "number") s.loudness = NaN
                internalModel.append(s)
            }
        } catch(e) {
            console.warn("Failed to parse stations Json", e)
        }
    }

    function saveModel() {
        var stations = []
        for (var i = 0; i < internalModel.count; i++) {
            var item = internalModel.get(i)
            var st = {
                "name": item.name,
                "city": item.city,
                "url": item.url,
                "website": item.website || "",
                "donate": item.donate || "",
                "icon": item.icon || "audio-x-generic"
            }
            if (item.lat !== undefined && item.lat !== "") st["lat"] = parseFloat(item.lat)
            if (item.lon !== undefined && item.lon !== "") st["lon"] = parseFloat(item.lon)
            if (typeof item.loudness === "number" && !isNaN(item.loudness)) st["loudness"] = item.loudness
            stations.push(st)
        }
        cfg_stationsJson = JSON.stringify(stations)
    }

    ColumnLayout {
        anchors.fill: parent
        
        // Precise padding to match system pages
        anchors.topMargin: Kirigami.Units.largeSpacing + 3
        anchors.bottomMargin: Kirigami.Units.largeSpacing + 3
        anchors.leftMargin: Kirigami.Units.gridUnit
        anchors.rightMargin: Kirigami.Units.gridUnit
        
        spacing: Kirigami.Units.smallSpacing

        // --- Page Title ---
        Kirigami.Heading {
            text: "Radio Stations"
            level: 1 // Massive page title, matching 'About'
            Layout.fillWidth: true
            Layout.bottomMargin: Kirigami.Units.largeSpacing // Space below main title
        }

        // --- Header / Toolbar ---
        RowLayout {
            Layout.fillWidth: true
            
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                
                Kirigami.Heading {
                    text: "Station List"
                    level: 4 // Demoted from 3 to 4
                    Layout.fillWidth: true
                }
                PlasmaComponents.Label {
                    text: "Manage the list of stations available in the widget."
                    opacity: 0.7
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    Layout.bottomMargin: Kirigami.Units.smallSpacing
                }
            }

            Item { Layout.fillWidth: true } // Flexible spacer

            PlasmaComponents.Button {
                text: "Add New Station"
                icon.name: "list-add"
                onClicked: {
                    internalModel.insert(0, {"name": "New Station", "city": "City, ST", "url": "https://...", "website": "", "donate": "", "lat": "", "lon": "", "icon": "audio-x-generic"})
                    saveModel()
                }
            }
        }

        // --- Station List ---
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ListView {
                id: stationList
                model: internalModel
                clip: true
                
                topMargin: Kirigami.Units.smallSpacing
                bottomMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                delegate: Item {
                    width: stationList.width
                    height: layout.implicitHeight
                    
                    property bool isExpanded: false

                    ColumnLayout {
                        id: layout
                        anchors.left: parent.left
                        anchors.right: parent.right
                        spacing: 0

                        // Always Visible Header
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: Kirigami.Units.iconSizes.large + Kirigami.Units.smallSpacing * 2
                            color: Kirigami.Theme.alternateBackgroundColor
                            radius: Kirigami.Units.smallSpacing
                            
                            RowLayout {
                                anchors.fill: parent
                                anchors.margins: Kirigami.Units.smallSpacing
                                
                                PlasmaComponents.ToolButton {
                                    icon.name: isExpanded ? "arrow-down" : "arrow-right"
                                    onClicked: isExpanded = !isExpanded
                                }

                                // Header is a read-only summary; editing happens in the expanded form.
                                PlasmaComponents.Label {
                                    Layout.fillWidth: true
                                    Layout.preferredWidth: 2
                                    text: model.name || "Unnamed Station"
                                    font.weight: Font.Bold
                                    elide: Text.ElideRight
                                }

                                PlasmaComponents.Label {
                                    Layout.fillWidth: true
                                    Layout.preferredWidth: 1
                                    text: model.city || ""
                                    opacity: 0.7
                                    elide: Text.ElideRight
                                }

                                PlasmaComponents.ToolButton {
                                    icon.name: "delete"
                                    PlasmaComponents.ToolTip { text: "Delete Station" }
                                    onClicked: {
                                        internalModel.remove(index)
                                        saveModel()
                                    }
                                }
                            }
                        }

                        // Expanded Details
                        Item {
                            Layout.fillWidth: true
                            Layout.preferredHeight: isExpanded ? formLayout.implicitHeight + Kirigami.Units.largeSpacing : 0
                            visible: isExpanded
                            clip: true
                            
                            Behavior on Layout.preferredHeight {
                                NumberAnimation { duration: Kirigami.Units.shortDuration; easing.type: Easing.InOutQuad }
                            }

                            Kirigami.FormLayout {
                                id: formLayout
                                anchors.top: parent.top
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.margins: Kirigami.Units.largeSpacing
                                
                                PlasmaComponents.TextField {
                                    Kirigami.FormData.label: "Name:"
                                    Layout.fillWidth: true
                                    text: model.name
                                    placeholderText: "Station Name"
                                    onTextChanged: {
                                        if (model.name !== text) {
                                            internalModel.setProperty(index, "name", text)
                                            saveModel()
                                        }
                                    }
                                }

                                PlasmaComponents.TextField {
                                    Kirigami.FormData.label: "Location:"
                                    Layout.fillWidth: true
                                    text: model.city
                                    placeholderText: "City, ST"
                                    onTextChanged: {
                                        if (model.city !== text) {
                                            internalModel.setProperty(index, "city", text)
                                            saveModel()
                                        }
                                    }
                                }

                                PlasmaComponents.TextField {
                                    Kirigami.FormData.label: "Stream URL:"
                                    Layout.fillWidth: true
                                    text: model.url
                                    placeholderText: "https://stream.example.com/live.mp3"
                                    onTextChanged: {
                                        if (model.url !== text) {
                                            internalModel.setProperty(index, "url", text)
                                            saveModel()
                                        }
                                    }
                                }
                                
                                PlasmaComponents.TextField {
                                    Kirigami.FormData.label: "Website URL:"
                                    Layout.fillWidth: true
                                    text: model.website || ""
                                    placeholderText: "https://station.example.com/playlist"
                                    onTextChanged: {
                                        if (model.website !== text) {
                                            internalModel.setProperty(index, "website", text)
                                            saveModel()
                                        }
                                    }
                                }
                                
                                PlasmaComponents.TextField {
                                    Kirigami.FormData.label: "Donate URL:"
                                    Layout.fillWidth: true
                                    text: model.donate || ""
                                    placeholderText: "https://station.example.com/donate"
                                    onTextChanged: {
                                        if (model.donate !== text) {
                                            internalModel.setProperty(index, "donate", text)
                                            saveModel()
                                        }
                                    }
                                }
                                
                                RowLayout {
                                    Kirigami.FormData.label: "Coordinates:"
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing
                                    
                                    PlasmaComponents.TextField {
                                        Layout.fillWidth: true
                                        text: model.lat !== undefined ? String(model.lat) : ""
                                        placeholderText: "Latitude (e.g. 40.71)"
                                        onTextChanged: {
                                            if (String(model.lat) !== text) {
                                                internalModel.setProperty(index, "lat", text)
                                                saveModel()
                                            }
                                        }
                                    }
                                    PlasmaComponents.TextField {
                                        Layout.fillWidth: true
                                        text: model.lon !== undefined ? String(model.lon) : ""
                                        placeholderText: "Longitude (e.g. -74.00)"
                                        onTextChanged: {
                                            if (String(model.lon) !== text) {
                                                internalModel.setProperty(index, "lon", text)
                                                saveModel()
                                            }
                                        }
                                    }
                                }
                                
                                PlasmaComponents.ComboBox {
                                    Kirigami.FormData.label: "Station Type:"
                                    Layout.fillWidth: true
                                    
                                    // Manually bind the model's icon property to our combo box index
                                    property var iconMapping: ["emblem-music-symbolic", "mic-on-symbolic", "mixed-composite"]
                                    
                                    model: ["Music", "Talk / Arts", "Mixed / Variety"]
                                    
                                    currentIndex: {
                                        var currentIcon = model.icon || "audio-x-generic"
                                        var idx = iconMapping.indexOf(currentIcon)
                                        return idx !== -1 ? idx : 0
                                    }
                                    
                                    onActivated: {
                                        var selectedIcon = iconMapping[currentIndex]
                                        if (model.icon !== selectedIcon) {
                                            internalModel.setProperty(index, "icon", selectedIcon)
                                            saveModel()
                                        }
                                    }
                                }

                                // Loudness level: measured (automatic) or hand-set (manual).
                                RowLayout {
                                    Kirigami.FormData.label: "Level:"
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing

                                    readonly property real adj: configRoot.adjustmentDb(Number(model.loudness))

                                    // Automatic: read-only measured result.
                                    PlasmaComponents.Label {
                                        visible: configRoot.cfg_loudnessAuto
                                        text: {
                                            if (isNaN(parent.adj)) return "measuring…"
                                            var dbStr = parent.adj <= -0.05 ? parent.adj.toFixed(1) + " dB" : "0 dB"
                                            return dbStr + "   (" + Number(model.loudness).toFixed(1) + " LUFS)"
                                        }
                                        opacity: 0.7
                                        HoverHandler { id: levelHover }
                                        PlasmaComponents.ToolTip {
                                            visible: levelHover.hovered
                                            text: "Turn off \"Measure levels automatically\" (Loudness tab) to set this manually."
                                        }
                                    }

                                    // Manual: editable attenuation in dB.
                                    PlasmaComponents.TextField {
                                        visible: !configRoot.cfg_loudnessAuto
                                        Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                                        horizontalAlignment: TextInput.AlignRight
                                        text: !isNaN(parent.adj) ? parent.adj.toFixed(1) : ""
                                        placeholderText: "0"
                                        validator: DoubleValidator { bottom: -24.0; top: 0.0; decimals: 1; notation: DoubleValidator.StandardNotation }
                                        onEditingFinished: {
                                            var v = parseFloat(text)
                                            if (isNaN(v)) {
                                                internalModel.setProperty(index, "loudness", NaN) // clear -> use default
                                            } else {
                                                if (v > 0) v = 0
                                                if (v < -24) v = -24
                                                internalModel.setProperty(index, "loudness", configRoot.loudnessTarget - v)
                                            }
                                            saveModel()
                                        }
                                    }
                                    PlasmaComponents.Label {
                                        visible: !configRoot.cfg_loudnessAuto
                                        text: "dB attenuation (boost not possible)"
                                        opacity: 0.5
                                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}