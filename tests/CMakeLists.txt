add_executable(test_icystream
    test_icystream.cpp
)

target_link_libraries(test_icystream
    PRIVATE
    patronradiocore
    Qt::Test
)

add_test(NAME test_icystream COMMAND test_icystream)

add_executable(test_radiobackend
    test_radiobackend.cpp
)

target_link_libraries(test_radiobackend
    PRIVATE
    patronradiocore
    Qt::Test
)

add_test(NAME test_radiobackend COMMAND test_radiobackend)
