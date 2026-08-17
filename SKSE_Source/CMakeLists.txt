cmake_minimum_required(VERSION 3.21)

project(SkyrimNetKinship VERSION 0.1.0 LANGUAGES CXX)

# ---------------------------------------------------------------------------
# Where the built DLL is copied. Point this at a Vortex staging folder or your
# Data directory. Left as a cache variable rather than hardcoded, so it does not
# need editing to build - unlike the Lover's Ledger CMakeLists this was modelled
# on, which bakes in an absolute path.
# ---------------------------------------------------------------------------
set(KINSHIP_DEPLOY_DIR "" CACHE PATH "Optional folder to copy the built .dll into (e.g. a Vortex mod folder)")

set(CommonLibPath "extern/CommonLibSSE-NG")
set(CommonLibName "CommonLibSSE")

set(BUILD_TESTS OFF CACHE BOOL "" FORCE)

# Static everything: an SKSE plugin must not drag a runtime DLL alongside it.
set(VCPKG_TARGET_TRIPLET "x64-windows-static" CACHE STRING "")
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>" CACHE STRING "" FORCE)

if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${CommonLibPath}/CMakeLists.txt")
    message(FATAL_ERROR
        "CommonLibSSE-NG is missing at ${CommonLibPath}.\n"
        "Fetch it first:\n"
        "  git clone https://github.com/alandtse/CommonLibVR.git --branch ng --recursive ${CommonLibPath}\n"
        "See docs/BUILD_DLL.md.")
endif()

# CommonLibSSE-NG expects RAPIDCSV_INCLUDE_DIRS to be set by the CONSUMING
# project and fails at generate time with "set to NOTFOUND" if it is not. This
# must therefore run BEFORE add_subdirectory, not after.
#
# directxtk and rapidcsv are likewise CommonLibSSE-NG's dependencies, not ours -
# nothing in this plugin touches either. They were dropped from vcpkg.json on
# the assumption they belonged to the project this build was modelled on, and
# both had to come back. If a future dependency looks unused, check whether
# CommonLib wants it before removing it.
find_path(RAPIDCSV_INCLUDE_DIRS
    NAMES rapidcsv.h
    PATH_SUFFIXES rapidcsv
    REQUIRED
)

add_subdirectory(${CommonLibPath} ${CommonLibName} EXCLUDE_FROM_ALL)

find_package(nlohmann_json CONFIG REQUIRED)
find_package(spdlog CONFIG REQUIRED)

set(SOURCES
    plugin.cpp
    src/KinshipPanel.cpp
    src/PapyrusBridge.cpp
    src/Store.cpp
)

# add_commonlibsse_plugin, NOT add_library(SHARED).
#
# THIS IS WHAT MAKES SKSE LOAD THE DLL AT ALL. The helper generates the plugin
# version declaration SKSE reads at startup; a plain shared library builds and
# deploys perfectly and is then rejected with
#
#     plugin SkyrimNetKinship.dll (00000000 00000000) no version data 0
#
# in skse64.log, with nothing wrong anywhere else. The DLL existed, was in the
# right folder, and never ran.
include("${CommonLibPath}/cmake/CommonLibSSE.cmake")
add_commonlibsse_plugin(${PROJECT_NAME} SOURCES ${SOURCES} ${CMAKE_CURRENT_SOURCE_DIR}/PCH.h)

target_compile_features(${PROJECT_NAME} PRIVATE cxx_std_23)
target_precompile_headers(${PROJECT_NAME} PRIVATE PCH.h)

target_include_directories(${PROJECT_NAME} PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_link_libraries(${PROJECT_NAME} PRIVATE
    CommonLibSSE::CommonLibSSE
    nlohmann_json::nlohmann_json
    spdlog::spdlog
)

# UNICODE/_UNICODE are REQUIRED, not stylistic. SKSEMenuFramework.h calls
# GetModuleHandle(L"SKSEMenuFramework") with a wide literal; without these the
# macro resolves to the ANSI GetModuleHandleA and the header fails to compile
# with "cannot convert from 'const wchar_t [18]' to 'LPCSTR'".
target_compile_definitions(${PROJECT_NAME} PRIVATE
    UNICODE
    _UNICODE
    WIN32_LEAN_AND_MEAN
    NOMINMAX
)

if(MSVC)
    target_compile_options(${PROJECT_NAME} PRIVATE
        /W4
        /permissive-
        /Zc:preprocessor
        /utf-8            # the sources contain non-ASCII in comments
        # The vendored SKSEMenuFramework.h is third-party and trips several
        # warnings we cannot fix without editing someone else's header:
        #   C4099 struct/class mismatch on ImGuiTextFilter
        #   C5054 deprecated | between different enum types
        /wd4099
        /wd5054
    )
endif()

if(KINSHIP_DEPLOY_DIR)
    add_custom_command(TARGET ${PROJECT_NAME} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory "${KINSHIP_DEPLOY_DIR}/SKSE/Plugins"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "$<TARGET_FILE:${PROJECT_NAME}>"
                "${KINSHIP_DEPLOY_DIR}/SKSE/Plugins/"
        COMMENT "Deploying to ${KINSHIP_DEPLOY_DIR}/SKSE/Plugins")
endif()
