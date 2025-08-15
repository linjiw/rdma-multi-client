# Contributing to Secure RDMA

Thank you for your interest in contributing to the Secure RDMA project! We welcome contributions from the community.

## How to Contribute

### Reporting Issues

- Check if the issue already exists
- Include system information (OS, kernel, RDMA hardware)
- Provide steps to reproduce
- Include relevant logs and error messages

### Submitting Pull Requests

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Run tests (`make test`)
5. Commit with descriptive message (`git commit -m 'feat: Add amazing feature'`)
6. Push to your fork (`git push origin feature/amazing-feature`)
7. Open a Pull Request

### Coding Standards

- Follow existing code style
- Add tests for new features
- Update documentation as needed
- Ensure all tests pass

### Commit Message Format

We use conventional commits:
- `feat:` New feature
- `fix:` Bug fix
- `docs:` Documentation changes
- `test:` Test additions/changes
- `refactor:` Code refactoring
- `perf:` Performance improvements

## Development Setup

```bash
# Clone your fork
git clone https://github.com/YOUR_USERNAME/rmda-multi-client.git
cd rmda-multi-client

# Add upstream remote
git remote add upstream https://github.com/linjiw/rmda-multi-client.git

# Install dependencies
sudo apt-get install -y libibverbs-dev librdmacm-dev libssl-dev

# Build
make clean && make all

# Run tests
make test
```

## Testing

- Test with both hardware RDMA and Soft-RoCE
- Verify multi-client scenarios
- Check for memory leaks with valgrind
- Test on different platforms if possible

## Questions?

Feel free to open an issue for any questions about contributing.