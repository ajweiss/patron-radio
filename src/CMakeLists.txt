set(DBUS_ADAPTOR_SRCS)
qt_add_dbus_adaptor(DBUS_ADAPTOR_SRCS org.mpris.MediaPlayer2.xml radiobackend.h RadioBackend mprisrootadaptor MprisRootAdaptor)
qt_add_dbus_adaptor(DBUS_ADAPTOR_SRCS org.mpris.MediaPlayer2.Player.xml radiobackend.h RadioBackend mprisplayeradaptor MprisPlayerAdaptor)

# Core backend logic library (used by both plugin and tests)
add_library(patronradiocore STATIC
    icystreamreader.cpp
    icystreamreader.h
    radiobackend.cpp
    radiobackend.h
    ${DBUS_ADAPTOR_SRCS}
)

target_link_libraries(patronradiocore PUBLIC
    Qt::Core
    Qt::Multimedia
    Qt::Network
    Qt::DBus
)

# Our QML plugin library
add_library(patronradioplugin MODULE
    radiobackendplugin.h
    com.signal11.patronradio.json
)

# Ensure the plugin has the 'lib' prefix and correct name for QML to find it
set_target_properties(patronradioplugin PROPERTIES 
    PREFIX "lib"
    OUTPUT_NAME "patronradioplugin"
    INSTALL_RPATH "$ORIGIN"
)

target_link_libraries(patronradioplugin PRIVATE
    patronradiocore
    Qt::Qml
    Qt::Quick
)

# Install the QML plugin library and qmldir
set(INSTALL_DESTINATION ${KDE_INSTALL_DATADIR}/plasma/plasmoids/com.signal11.patronradio/contents/imports/com/signal11/patronradio)

install(TARGETS patronradioplugin
    LIBRARY DESTINATION ${INSTALL_DESTINATION}
)

install(FILES qmldir DESTINATION ${INSTALL_DESTINATION})
