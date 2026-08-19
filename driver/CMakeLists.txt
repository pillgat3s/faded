cmake_minimum_required(VERSION 3.20)
project(FaderDriver CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "")

# ---- knobs -----------------------------------------------------------------
set(CODESIGN_ID "-" CACHE STRING "codesign identity ('-' = ad-hoc)")
option(FADER_DEBUG_TRACE "Send libASPL traces to syslog (very chatty)" OFF)
option(FADER_TAP_VISIBLE "Make the Fader Tap input device visible (debugging)" OFF)

set(DRIVER_NAME       "FaderDriver")
set(DRIVER_VERSION    "0.1.0")
set(DRIVER_COPYRIGHT  "andri")
set(DRIVER_IDENTIFIER "com.andri.fader.driver")
# CFPlugIn factory UUID — must match Info.plist.in and be unique to this driver.
set(DRIVER_UID        "5C7B9D8E-3A31-4E48-9F0B-8F1D2C6A7E10")
set(DRIVER_ENTRYPOINT "FaderDriverEntryPoint")

# ---- libASPL (vendored, MIT) ----------------------------------------------
# libASPL's CMakeLists tries `git describe` for a version; vendored copy has no
# .git so it warns — harmless.
add_subdirectory(third_party/libASPL EXCLUDE_FROM_ALL)

# ---- the driver bundle -----------------------------------------------------
add_library(${DRIVER_NAME} MODULE
  Driver.cpp
  FaderFIFO.hpp
  FaderProtocol.h
)
target_link_libraries(${DRIVER_NAME} PRIVATE libASPL)
target_include_directories(${DRIVER_NAME} PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${CMAKE_CURRENT_SOURCE_DIR}/third_party/libASPL/include
)
find_library(LIB_CoreFoundation CoreFoundation REQUIRED)
find_library(LIB_CoreAudio CoreAudio REQUIRED)
target_link_libraries(${DRIVER_NAME} PRIVATE ${LIB_CoreFoundation} ${LIB_CoreAudio})
target_compile_options(${DRIVER_NAME} PRIVATE -Wall -Wextra -Wno-unused-parameter -fvisibility=hidden)
if(FADER_DEBUG_TRACE)
  target_compile_definitions(${DRIVER_NAME} PRIVATE FADER_DEBUG_TRACE=1)
endif()
if(FADER_TAP_VISIBLE)
  target_compile_definitions(${DRIVER_NAME} PRIVATE FADER_TAP_VISIBLE=1)
endif()

set_target_properties(${DRIVER_NAME} PROPERTIES
  OUTPUT_NAME "${DRIVER_NAME}"
  BUNDLE true
  BUNDLE_EXTENSION "driver"
  PREFIX ""
  SUFFIX ""
  MACOSX_BUNDLE ON
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
  MACOSX_BUNDLE_BUNDLE_NAME "${DRIVER_NAME}"
  MACOSX_BUNDLE_BUNDLE_VERSION "${DRIVER_VERSION}"
  MACOSX_BUNDLE_COPYRIGHT "${DRIVER_COPYRIGHT}"
  MACOSX_BUNDLE_GUI_IDENTIFIER "${DRIVER_IDENTIFIER}"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "${DRIVER_VERSION}"
)

# coreaudiod only loads signed plug-ins on recent macOS; ad-hoc is fine for
# a locally-built personal driver, a Developer ID/Development cert also works.
add_custom_command(TARGET ${DRIVER_NAME} POST_BUILD
  COMMENT "codesign ${DRIVER_NAME}.driver (${CODESIGN_ID})"
  VERBATIM
  COMMAND codesign --force --timestamp=none -s "${CODESIGN_ID}"
          "$<TARGET_BUNDLE_DIR:${DRIVER_NAME}>"
)
