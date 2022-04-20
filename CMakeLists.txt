cmake_minimum_required(VERSION 3.13)
project(ycm.nvim VERSION 0.0.1 LANGUAGES CXX)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_CXX_STANDARD 17)

# Download automatically, you can also just copy the conan.cmake file
if(NOT EXISTS "${CMAKE_BINARY_DIR}/conan.cmake")
   message(STATUS "Downloading conan.cmake from https://github.com/conan-io/cmake-conan")
   file(DOWNLOAD "https://github.com/conan-io/cmake-conan/raw/v0.15/conan.cmake"
                 "${CMAKE_BINARY_DIR}/conan.cmake" 
                 TLS_VERIFY ON)
endif()

include(${CMAKE_BINARY_DIR}/conan.cmake)

conan_check(REQUIRED)
conan_cmake_run(CONANFILE conanfile.txt
                BASIC_SETUP CMAKE_TARGETS
                BUILD missing)

set(CMAKE_MODULE_PATH ${CMAKE_BINARY_DIR})

find_package(asio 1.4.1 REQUIRED)
find_package(msgpack 3.2.1 REQUIRED)
find_package(absl 20211102.0 REQUIRED)

set(YCMD_DIR third_party/ycmd/cpp/ycm)

set(YCMD_SOURCES
"${YCMD_DIR}/Candidate.cpp"
"${YCMD_DIR}/IdentifierCompleter.cpp"
"${YCMD_DIR}/IdentifierDatabase.cpp"
"${YCMD_DIR}/CodePoint.cpp"
"${YCMD_DIR}/Repository.cpp"
"${YCMD_DIR}/Word.cpp"
"${YCMD_DIR}/Result.cpp"
"${YCMD_DIR}/Character.cpp"
"${YCMD_DIR}/IdentifierUtils.cpp"
"${YCMD_DIR}/Utils.cpp"
)


add_library( ycmd_static STATIC ${YCMD_SOURCES} )
target_include_directories( ycmd_static PRIVATE ${YCMD_DIR})
target_link_libraries(ycmd_static absl::flat_hash_map absl::flat_hash_set)
target_compile_definitions( ycmd_static PUBLIC YCM_ABSEIL_SUPPORTED )
target_compile_definitions( ycmd_static PUBLIC YCM_EXPORT= )

add_executable(ycm "src/main.cpp")
target_include_directories( ycm PRIVATE ${YCMD_DIR})
target_link_libraries(ycm ycmd_static asio::asio msgpack::msgpack)
# XXX(AC): we have to integrate with ycmd build system
