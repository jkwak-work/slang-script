#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <optional>
#include <string>
#include <string_view>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

namespace {

constexpr std::string_view kDefaultGit = "/mnt/c/Program Files/Git/cmd/git.exe";

bool is_executable(const std::string& path) {
    return !path.empty() && ::access(path.c_str(), X_OK) == 0;
}

std::optional<std::string> find_on_path(std::string_view program) {
    const char* path_value = std::getenv("PATH");
    if (path_value == nullptr) {
        return std::nullopt;
    }

    std::string_view path(path_value);
    std::size_t start = 0;
    for (;;) {
        const std::size_t end = path.find(':', start);
        const std::string_view directory =
            path.substr(start, end == std::string_view::npos ? end : end - start);

        std::string candidate;
        if (directory.empty()) {
            candidate.assign(program);
        } else {
            candidate.reserve(directory.size() + 1 + program.size());
            candidate.assign(directory);
            candidate.push_back('/');
            candidate.append(program);
        }

        if (is_executable(candidate)) {
            return candidate;
        }
        if (end == std::string_view::npos) {
            break;
        }
        start = end + 1;
    }
    return std::nullopt;
}

bool is_windows_path(std::string_view argument) {
    const bool drive_path =
        argument.size() >= 2 &&
        ((argument[0] >= 'A' && argument[0] <= 'Z') ||
         (argument[0] >= 'a' && argument[0] <= 'z')) &&
        argument[1] == ':';
    const bool unc_path = argument.size() >= 2 && argument[0] == '\\' && argument[1] == '\\';
    return drive_path || unc_path;
}

// Runs wslpath directly, never through a command shell. A failure simply leaves
// the argument untouched, matching the behavior of the original wrapper.
std::optional<std::string> convert_path(const std::string& wslpath,
                                        const std::string& value) {
    int output_pipe[2];
    if (::pipe(output_pipe) != 0) {
        return std::nullopt;
    }

    const pid_t child = ::fork();
    if (child == -1) {
        ::close(output_pipe[0]);
        ::close(output_pipe[1]);
        return std::nullopt;
    }

    if (child == 0) {
        ::close(output_pipe[0]);
        if (::dup2(output_pipe[1], STDOUT_FILENO) == -1) {
            _exit(127);
        }
        ::close(output_pipe[1]);

        const int null_fd = ::open("/dev/null", O_WRONLY | O_CLOEXEC);
        if (null_fd >= 0) {
            (void)::dup2(null_fd, STDERR_FILENO);
            ::close(null_fd);
        }

        char* const child_argv[] = {
            const_cast<char*>(wslpath.c_str()),
            const_cast<char*>("-w"),
            const_cast<char*>("--"),
            const_cast<char*>(value.c_str()),
            nullptr,
        };
        ::execv(wslpath.c_str(), child_argv);
        _exit(127);
    }

    ::close(output_pipe[1]);
    std::string output;
    char buffer[4096];
    bool read_succeeded = true;
    for (;;) {
        const ssize_t count = ::read(output_pipe[0], buffer, sizeof(buffer));
        if (count > 0) {
            output.append(buffer, static_cast<std::size_t>(count));
        } else if (count == 0) {
            break;
        } else if (errno != EINTR) {
            read_succeeded = false;
            break;
        }
    }
    ::close(output_pipe[0]);

    int status = 0;
    while (::waitpid(child, &status, 0) == -1) {
        if (errno != EINTR) {
            return std::nullopt;
        }
    }
    if (!read_succeeded || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        return std::nullopt;
    }

    // Bash command substitution removes every trailing newline.
    while (!output.empty() && output.back() == '\n') {
        output.pop_back();
    }
    return output;
}

std::string converted_argument(const std::string& argument,
                               const std::optional<std::string>& wslpath) {
    if (is_windows_path(argument) || !wslpath) {
        return argument;
    }

    std::size_t value_start = 0;
    if (argument.starts_with('-')) {
        const std::size_t equals = argument.find('=');
        if (equals != std::string::npos && equals + 1 < argument.size() &&
            argument[equals + 1] == '/') {
            value_start = equals + 1;
        }
    }

    if (value_start == 0 && (argument.empty() || argument[0] != '/')) {
        return argument;
    }

    const std::string value = argument.substr(value_start);
    const auto converted = convert_path(*wslpath, value);
    if (!converted) {
        return argument;
    }
    return argument.substr(0, value_start) + *converted;
}

std::string shell_quote(std::string_view value) {
    if (value.empty()) {
        return "''";
    }
    bool safe = true;
    for (const unsigned char c : value) {
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || std::string_view("_@%+=:,./-").find(c) !=
                                             std::string_view::npos)) {
            safe = false;
            break;
        }
    }
    if (safe) {
        return std::string(value);
    }

    std::string quoted("'");
    for (const char c : value) {
        if (c == '\'') {
            quoted += "'\\''";
        } else {
            quoted.push_back(c);
        }
    }
    quoted.push_back('\'');
    return quoted;
}

}  // namespace

int main(int argc, char* argv[]) {
    std::optional<std::string> git;
    if (is_executable(std::string(kDefaultGit))) {
        git = std::string(kDefaultGit);
    } else {
        git = find_on_path("git.exe");
    }
    if (!git) {
        std::cerr << "git proxy: git.exe not found\n";
        return 127;
    }

    const auto wslpath = find_on_path("wslpath");
    std::vector<std::string> arguments;
    arguments.reserve(static_cast<std::size_t>(argc));
    arguments.push_back(*git);
    for (int index = 1; index < argc; ++index) {
        arguments.push_back(converted_argument(argv[index], wslpath));
    }

    if (const char* trace = std::getenv("GIT_PROXY_TRACE"); trace != nullptr && trace[0] != '\0') {
        std::cerr << "git proxy:";
        for (const auto& argument : arguments) {
            std::cerr << ' ' << shell_quote(argument);
        }
        std::cerr << '\n';
    }

    std::vector<char*> exec_arguments;
    exec_arguments.reserve(arguments.size() + 1);
    for (auto& argument : arguments) {
        exec_arguments.push_back(argument.data());
    }
    exec_arguments.push_back(nullptr);

    ::execv(git->c_str(), exec_arguments.data());
    const int error = errno;
    std::cerr << "git proxy: cannot execute " << *git << ": " << std::strerror(error) << '\n';
    return error == ENOENT ? 127 : 126;
}
