# Waffle ModPlayer – the easter egg of waffle-fuse (Qt 6, libmikmod)
#
#   cmake -S modplayer -B modplayer/build -DCMAKE_BUILD_TYPE=Release
#   cmake --build modplayer/build
#
# or `make modplayer` from the top directory.

cmake_minimum_required(VERSION 3.16)
project(waffle-modplayer LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

set(WAFFLE_VERSION "dev" CACHE STRING "Version shown by --version")

find_package(Qt6 6.2 REQUIRED COMPONENTS Widgets Network)
find_package(PkgConfig REQUIRED)
pkg_check_modules(MIKMOD REQUIRED libmikmod)
# Release builds: libmikmod built by build-libmikmod.sh, linked statically
option(MIKMOD_STATIC "Link libmikmod statically" OFF)

set(SOURCES
    src/main.cpp
    src/modengine.cpp src/modengine.h
    src/playerwindow.cpp src/playerwindow.h
    src/sinescroller.cpp src/sinescroller.h
    src/vumeterwidget.cpp src/vumeterwidget.h
    src/waffledisk.cpp src/waffledisk.h
    resources/modplayer.qrc)

if(WIN32)
    list(APPEND SOURCES resources/waffle-modplayer.rc)
endif()

if(APPLE)
    set(MACOSX_BUNDLE_ICON_FILE waffle-modplayer.icns)
    set(ICNS ${CMAKE_CURRENT_SOURCE_DIR}/resources/waffle-modplayer.icns)
    if(EXISTS ${ICNS})
        set_source_files_properties(${ICNS} PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
        list(APPEND SOURCES ${ICNS})
    endif()
endif()

add_executable(waffle-modplayer WIN32 MACOSX_BUNDLE ${SOURCES})
target_compile_definitions(waffle-modplayer PRIVATE WAFFLE_VERSION="${WAFFLE_VERSION}")
target_link_libraries(waffle-modplayer PRIVATE Qt6::Widgets Qt6::Network)
target_include_directories(waffle-modplayer PRIVATE ${MIKMOD_INCLUDE_DIRS})
if(MIKMOD_STATIC)
    target_compile_definitions(waffle-modplayer PRIVATE MIKMOD_STATIC)
    target_link_directories(waffle-modplayer PRIVATE ${MIKMOD_STATIC_LIBRARY_DIRS})
    target_link_libraries(waffle-modplayer PRIVATE ${MIKMOD_STATIC_LIBRARIES})
    if(APPLE)
        target_link_libraries(waffle-modplayer PRIVATE "-framework CoreAudio" "-framework AudioUnit" "-framework AudioToolbox" "-framework CoreServices")
    elseif(WIN32)
        target_link_libraries(waffle-modplayer PRIVATE winmm dsound dxguid ole32)
    else()
        find_package(Threads REQUIRED)
        target_link_libraries(waffle-modplayer PRIVATE Threads::Threads m)
    endif()
else()
    target_link_directories(waffle-modplayer PRIVATE ${MIKMOD_LIBRARY_DIRS})
    target_link_libraries(waffle-modplayer PRIVATE ${MIKMOD_LIBRARIES})
endif()

# Linux packages: the Qt libraries go in lib/ next to the binary (bundle-linux.sh)
option(MODPLAYER_BUNDLE "Look for the libraries in lib/ next to the binary" OFF)
if(MODPLAYER_BUNDLE AND UNIX AND NOT APPLE)
    set_target_properties(waffle-modplayer PROPERTIES
        BUILD_WITH_INSTALL_RPATH ON
        INSTALL_RPATH "\$ORIGIN/lib")
endif()

if(APPLE)
    set_target_properties(waffle-modplayer PROPERTIES
        OUTPUT_NAME "Waffle ModPlayer"
        MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/resources/Info.plist.in
        MACOSX_BUNDLE_GUI_IDENTIFIER io.github.gianlucarenzi.waffle-modplayer
        MACOSX_BUNDLE_BUNDLE_VERSION ${WAFFLE_VERSION}
        MACOSX_BUNDLE_SHORT_VERSION_STRING ${WAFFLE_VERSION})
endif()
