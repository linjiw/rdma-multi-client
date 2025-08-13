# Contributing to Secure RDMA Project

Thank you for your interest in contributing to the Secure RDMA with Pure IB Verbs project!

## How to Contribute

### Reporting Issues

1. Check if the issue already exists in the [Issues](https://github.com/yourusername/rdma-project/issues) section
2. Create a new issue with:
   - Clear description of the problem
   - Steps to reproduce
   - Expected behavior
   - System information (OS, RDMA hardware/Soft-RoCE)
   - Relevant logs

### Submitting Pull Requests

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/your-feature`)
3. Make your changes
4. Add/update tests as needed
5. Update documentation
6. Commit with clear messages (`git commit -m 'feat: add new feature'`)
7. Push to your fork (`git push origin feature/your-feature`)
8. Create a Pull Request

### Commit Message Format

We follow conventional commits:

- `feat:` New feature
- `fix:` Bug fix
- `docs:` Documentation changes
- `test:` Test additions/changes
- `refactor:` Code refactoring
- `perf:` Performance improvements
- `chore:` Maintenance tasks

### Code Style

- Follow existing code style
- Use meaningful variable names
- Add comments for complex logic
- Keep functions focused and small
- Check for memory leaks with Valgrind

### Testing

Before submitting:

1. Run the test suite:
   ```bash
   make test
   ./test_multi_client.sh
   ./test_thread_safety.sh
   ```

2. Verify the demo works:
   ```bash
   ./demo_cleanup.sh
   ./run_demo_auto.sh
   ```

3. Check for memory leaks:
   ```bash
   valgrind --leak-check=full ./build/secure_server
   ```

### Documentation

- Update README.md if adding features
- Add/update design docs in `docs/`
- Include Mermaid diagrams for complex flows
- Document any new configuration options

## Development Setup

1. Install dependencies:
   ```bash
   sudo apt-get install -y libibverbs-dev librdmacm-dev libssl-dev
   ```

2. Configure Soft-RoCE (if no RDMA hardware):
   ```bash
   sudo modprobe rdma_rxe
   sudo rdma link add rxe0 type rxe netdev eth0
   ```

3. Build the project:
   ```bash
   make clean && make all
   ```

## Areas for Contribution

- **Performance**: Optimize message throughput
- **Scalability**: Dynamic client allocation
- **Security**: Add mTLS support
- **Features**: Configuration file support
- **Testing**: Expand test coverage
- **Documentation**: Improve user guides
- **Platform**: Support for other OS/architectures

## Questions?

Feel free to open an issue for discussion or reach out to the maintainers.

Thank you for contributing!