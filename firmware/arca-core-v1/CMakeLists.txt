cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)

# ---------------------------------------------------------------------------
# Vendored-component build (IDF_COMPONENT_MANAGER=0)
#
# Managed components declare their dependencies in idf_component.yml, which only
# the component manager reads - their CMakeLists REQUIRES lists are incomplete on
# purpose. So when the components are vendored into ./components and the manager
# is off, every one of them fails to find its siblings' headers.
#
# Rather than patch each component's CMakeLists, make the vendored set visible to
# all components at once. This is the same mechanism IDF uses to make freertos
# and friends universally available.
#
# Only kicks in when the manager is actually off, so a normal
# `idf.py build` is completely unaffected.
# ---------------------------------------------------------------------------
if(DEFINED ENV{IDF_COMPONENT_MANAGER} AND "$ENV{IDF_COMPONENT_MANAGER}" STREQUAL "0")
    file(GLOB _vendored RELATIVE "${CMAKE_CURRENT_LIST_DIR}/components"
         "${CMAKE_CURRENT_LIST_DIR}/components/*")
    set(_common "")
    foreach(_c IN LISTS _vendored)
        if(IS_DIRECTORY "${CMAKE_CURRENT_LIST_DIR}/components/${_c}")
            list(APPEND _common "${_c}")
        endif()
    endforeach()
    message(STATUS "ARCA: vendored components made common: ${_common}")
    idf_build_set_property(__COMPONENT_REQUIRES_COMMON "${_common}" APPEND)
endif()

project(arca_core_v1)
