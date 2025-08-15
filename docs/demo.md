# Demo Placeholder

This is a placeholder for the demo GIF. To create an actual demo recording:

1. Run the demo script:
```bash
./run_demo_auto.sh
```

2. Record the terminal output using:
- asciinema
- terminalizer
- ttygif

3. Convert to GIF and place in docs/demo.gif

The demo shows:
- 10 concurrent clients connecting
- Unique PSN values for each connection
- Alphabet pattern messages (Client 1: 'aaa...', Client 2: 'bbb...', etc.)
- Successful message verification
- Zero replay attacks