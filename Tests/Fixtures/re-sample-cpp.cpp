// Fixture for Kiln's reverse-engineering tests (C++). Build: clang++ -O0 -arch arm64 -o Tests/Fixtures/re-sample-cpp Tests/Fixtures/re-sample-cpp.cpp
// Known facts: class Counter with methods add and total; free function describe prints KILN-CPP-FIXTURE; main uses both.
#include <cstdio>
class Counter {
public:
    int add(int n) { sum += n; return sum; }
    int total() const { return sum; }
private:
    int sum = 0;
};
void describe(int value) { std::printf("KILN-CPP-FIXTURE %d\n", value); }
int main() {
    Counter counter;
    counter.add(4);
    counter.add(5);
    describe(counter.total());
    return counter.total() == 9 ? 0 : 1;
}
