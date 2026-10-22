include Util/BuildTools/Vars.mk
ifeq ($(OS),Windows_NT)
include Util/BuildTools/Windows.mk
else ifeq ($(shell uname -s),Darwin)
include Util/BuildTools/Mac.mk
else
include Util/BuildTools/Linux.mk
endif
