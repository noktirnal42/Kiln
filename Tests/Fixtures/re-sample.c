// Fixture for Kiln's reverse-engineering tests. Build: clang -O0 -arch arm64 -o Tests/Fixtures/re-sample Tests/Fixtures/re-sample.c
// Known facts the tests rely on: functions add_numbers, scale_value, greet and main; main calls add_numbers and greet;
// greet prints the string KILN-FIXTURE-GREETING.
#include <stdio.h>

int add_numbers(int a, int b) { return a + b; }

int scale_value(int value) { return add_numbers(value, value) * 3; }

void greet(const char *name) { printf("KILN-FIXTURE-GREETING %s\n", name); }

int main(int argc, char **argv) {
    greet(argc > 1 ? argv[1] : "world");
    return add_numbers(2, 3) == 5 ? scale_value(7) - 42 : 1;
}
