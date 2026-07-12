cmake_minimum_required(VERSION 3.20)

project(PatronRadio VERSION 0.8)

set(QT_MIN_VERSION "6.5.0")
set(KF_MIN_VERSION "6.0.0")

find_package(ECM ${KF_MIN_VERSION} REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})

include(KDEInstallDirs)
include(KDECMakeSettings)
include(KDECompilerSettings NO_POLICY_SCOPE)
include(FeatureSummary)

find_package(Qt6 ${QT_MIN_VERSION} REQUIRED COMPONENTS Core Qml Quick Multimedia Network DBus Test)
find_package(KF6 ${KF_MIN_VERSION} REQUIRED COMPONENTS CoreAddons Config I18n KIO)

# Build Options
option(BUILD_TESTING "Build unit tests" ON)

add_subdirectory(src)

# Install standard Plasmoid files
install(DIRECTORY contents DESTINATION ${KDE_INSTALL_DATADIR}/plasma/plasmoids/com.signal11.patronradio)
install(FILES metadata.json DESTINATION ${KDE_INSTALL_DATADIR}/plasma/plasmoids/com.signal11.patronradio)

# Desktop entry so MPRIS controllers can resolve the player's name and icon
# (the backend advertises DesktopEntry=com.signal11.patronradio).
install(FILES com.signal11.patronradio.desktop DESTINATION ${KDE_INSTALL_APPSDIR})

# Translations: compile and install any po/<lang>/<domain>.po catalogs.
# Harmless until translations exist; the .pot template lives in po/.
ki18n_install(po)

# Testing
if(BUILD_TESTING)
    enable_testing()
    add_subdirectory(tests)
endif()

feature_summary(WHAT ALL INCLUDE_QUIET_PACKAGES FATAL_ON_MISSING_REQUIRED_PACKAGES)
