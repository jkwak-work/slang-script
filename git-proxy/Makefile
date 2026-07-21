CXX ?= c++
CXXFLAGS ?= -O2 -Wall -Wextra -Wpedantic
CPPFLAGS ?=

.PHONY: all clean

all: git-proxy

git-proxy: git-proxy.cpp
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -std=c++20 -o $@ $<

clean:
	$(RM) git-proxy
