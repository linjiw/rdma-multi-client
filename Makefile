CC = gcc
CFLAGS = -Wall -Wextra -O2 -g -D_GNU_SOURCE
LDFLAGS = -lrdmacm -libverbs -lpthread -lssl -lcrypto
MATH_LIBS = -lm

all: secure_server secure_client rdma_rag_demo

secure_server: src/secure_rdma_server.c src/tls_utils.c
	mkdir -p build
	$(CC) $(CFLAGS) -I./src -o build/$@ $^ $(LDFLAGS)

secure_client: src/secure_rdma_client.c src/tls_utils.c
	mkdir -p build
	$(CC) $(CFLAGS) -I./src -o build/$@ $^ $(LDFLAGS)

rdma_rag_demo: src/rdma_rag_demo.c
	mkdir -p build
	$(CC) $(CFLAGS) -I./src -o build/$@ $< $(LDFLAGS) $(MATH_LIBS)

generate-cert:
	openssl req -x509 -newkey rsa:4096 -keyout server.key -out server.crt -days 365 -nodes \
		-subj "/C=US/ST=State/L=City/O=Organization/CN=localhost"

clean:
	rm -f build/secure_server build/secure_client server.crt server.key *.o

test: all generate-cert
	@echo "Running basic test..."
	./build/secure_server &
	sleep 2
	echo "quit" | ./build/secure_client 127.0.0.1 localhost
	killall secure_server 2>/dev/null || true

.PHONY: all clean generate-cert test
