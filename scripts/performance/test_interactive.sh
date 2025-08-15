#!/usr/bin/expect -f

set timeout 10

spawn ./build/secure_client 172.31.34.15 localhost

expect "> "
send "send Hello from expect script\r"

expect "> "
send "send Second message\r"

expect "> "
send "quit\r"

expect eof