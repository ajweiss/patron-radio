import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents

Item {
    id: configRoot
    Layout.fillWidth: true
    Layout.fillHeight: true

    property string cfg_stationsJson: ""

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
                internalModel.append(stations[i])
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

                                PlasmaComponents.TextField {
                                    Layout.fillWidth: true
                                    Layout.preferredWidth: 2
                                    text: model.name
                                    placeholderText: "Station Name"
                                    font.weight: Font.Bold
                                    background: null
                                    onTextChanged: {
                                        if (model.name !== text) {
                                            internalModel.setProperty(index, "name", text)
                                            saveModel()
                                        }
                                    }
                                }

                                PlasmaComponents.TextField {
                                    Layout.fillWidth: true
                                    Layout.preferredWidth: 1
                                    text: model.city
                                    placeholderText: "City, ST"
                                    background: null
                                    onTextChanged: {
                                        if (model.city !== text) {
                                            internalModel.setProperty(index, "city", text)
                                            saveModel()
                                        }
                                    }
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
                            }
                        }
                    }
                }
            }
        }
    }
}