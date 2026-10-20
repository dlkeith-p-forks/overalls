cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "mila_platform.cpp"
  "single_instance.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Mila's native pieces (ADR-0235): CNG device keys, DPAPI poke keys,
# owner-only DACLs, and the portable poke opener from ../../native, built
# against Monocypher 4 from MILA_MONOCYPHER_DIR (a CMake or environment
# variable; `flutter build windows` passes the environment through).
if(NOT MILA_MONOCYPHER_DIR AND DEFINED ENV{MILA_MONOCYPHER_DIR})
  set(MILA_MONOCYPHER_DIR "$ENV{MILA_MONOCYPHER_DIR}")
endif()
set(MILA_NATIVE_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../../native"
  "${CMAKE_CURRENT_BINARY_DIR}/mila_native")
add_library(mila_runner_core STATIC
  "device_keys.cpp"
  "mila_text.cpp"
  "notification_text.cpp"
  "owner_only.cpp"
  "poke_keys.cpp"
)
apply_standard_settings(mila_runner_core)
target_compile_definitions(mila_runner_core PRIVATE "NOMINMAX")
target_include_directories(mila_runner_core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(mila_runner_core PUBLIC mila_poke
  "bcrypt.lib" "crypt32.lib" "ncrypt.lib" "advapi32.lib" "shell32.lib" "ole32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE mila_runner_core)

# WNS through the Windows App SDK, built only with MILA_WINDOWS_APP_SDK_DIR
# (extracted Microsoft.WindowsAppSDK* and Microsoft.Windows.CppWinRT NuGet
# packages, the 1.6 runtime the MSIX manifest depends on) and
# MILA_WNS_REMOTE_ID (the Entra ID application id, a GUID). C++/WinRT needs
# exceptions, which the Flutter settings disable, so it is its own library.
foreach(variable MILA_WINDOWS_APP_SDK_DIR MILA_WNS_REMOTE_ID)
  if(NOT ${variable} AND DEFINED ENV{${variable}})
    set(${variable} "$ENV{${variable}}")
  endif()
endforeach()
add_library(mila_push STATIC "mila_push.cpp")
target_link_libraries(mila_push PRIVATE mila_runner_core)
target_compile_definitions(mila_push PRIVATE "NOMINMAX" "UNICODE" "_UNICODE")
if(MILA_WINDOWS_APP_SDK_DIR)
  if(NOT MILA_WNS_REMOTE_ID MATCHES "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
    message(FATAL_ERROR "MILA_WINDOWS_APP_SDK_DIR needs MILA_WNS_REMOTE_ID, the Entra ID application GUID")
  endif()
  file(GLOB_RECURSE MILA_CPPWINRT "${MILA_WINDOWS_APP_SDK_DIR}/*/bin/cppwinrt.exe")
  file(GLOB_RECURSE MILA_APP_SDK_WINMD "${MILA_WINDOWS_APP_SDK_DIR}/*/metadata/*.winmd"
    "${MILA_WINDOWS_APP_SDK_DIR}/*/lib/uap10.0/*.winmd")
  file(GLOB_RECURSE MILA_APP_SDK_LIBS
    "${MILA_WINDOWS_APP_SDK_DIR}/*/lib/win10-x64/Microsoft.WindowsAppRuntime.lib")
  file(GLOB MILA_APP_SDK_INCLUDES LIST_DIRECTORIES true "${MILA_WINDOWS_APP_SDK_DIR}/*/include")
  list(GET MILA_CPPWINRT 0 MILA_CPPWINRT)
  if(NOT MILA_CPPWINRT OR NOT MILA_APP_SDK_WINMD OR NOT MILA_APP_SDK_LIBS)
    message(FATAL_ERROR "MILA_WINDOWS_APP_SDK_DIR lacks cppwinrt.exe, App SDK metadata or libraries")
  endif()
  # Projection headers for the Windows SDK and the App SDK metadata.
  set(MILA_WINRT_DIR "${CMAKE_CURRENT_BINARY_DIR}/winrt_projection")
  execute_process(
    COMMAND "${MILA_CPPWINRT}" -input sdk -input ${MILA_APP_SDK_WINMD} -output "${MILA_WINRT_DIR}"
    RESULT_VARIABLE MILA_CPPWINRT_RESULT)
  if(NOT MILA_CPPWINRT_RESULT EQUAL 0)
    message(FATAL_ERROR "cppwinrt failed to project the App SDK metadata")
  endif()
  target_compile_features(mila_push PRIVATE cxx_std_20)
  target_compile_options(mila_push PRIVATE /W4 /WX /EHsc /bigobj /permissive-)
  target_compile_definitions(mila_push PRIVATE "MILA_WINDOWS_APP_SDK"
    "MILA_WNS_REMOTE_ID=L\"${MILA_WNS_REMOTE_ID}\"")
  target_include_directories(mila_push PRIVATE "${MILA_WINRT_DIR}" ${MILA_APP_SDK_INCLUDES})
  target_link_libraries(mila_push PRIVATE ${MILA_APP_SDK_LIBS} "windowsapp.lib")
else()
  apply_standard_settings(mila_push)
endif()
target_link_libraries(${BINARY_NAME} PRIVATE mila_push)

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
