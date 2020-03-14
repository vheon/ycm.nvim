cmake_minimum_required(VERSION 3.13)
project(ycm.nvim VERSION 0.0.1 LANGUAGES CXX)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_CXX_STANDARD 17)

include_directories(./third_party/msgpack-c/include)
include_directories(./third_party/asio/asio/include)
add_compile_definitions(ASIO_STANDALONE)

# XXX(AC): we have to integrate with ycmd build system
add_definitions( -DYCM_EXPORT= )

set(YCMD_DIR third_party/ycmd/cpp/ycm)
include_directories(${YCMD_DIR})

set(YCMD_SOURCES
"${YCMD_DIR}/IdentifierCompleter.cpp"
"${YCMD_DIR}/IdentifierDatabase.cpp"
"${YCMD_DIR}/CandidateRepository.cpp"
"${YCMD_DIR}/CharacterRepository.cpp"
"${YCMD_DIR}/CodePoint.cpp"
"${YCMD_DIR}/CodePointRepository.cpp"
"${YCMD_DIR}/Word.cpp"
"${YCMD_DIR}/Candidate.cpp"
"${YCMD_DIR}/Result.cpp"
"${YCMD_DIR}/Character.cpp"
)

add_executable(ycm main.cpp ${YCMD_SOURCES})
