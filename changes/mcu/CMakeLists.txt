cmake_minimum_required(VERSION 3.5)

# Keep developer home/workspace paths out of __FILE__, assertions and debug info
# embedded in distributable firmware. Derive the prefix on each build machine.
get_filename_component(CHROMATIC_SOURCE_ROOT "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
add_compile_options("-ffile-prefix-map=${CHROMATIC_SOURCE_ROOT}/="
                    "-ffile-prefix-map=$ENV{IDF_PATH}/=esp-idf/")

add_definitions(-DLV_LVGL_H_INCLUDE_SIMPLE)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(mcu_fw)
