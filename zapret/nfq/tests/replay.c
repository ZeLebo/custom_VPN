// Exercise the real parser and packet path without opening utun or BPF.
#define main engine_main
#include "../nfqws.c"
#undef main

#include "../macsend.h"

static int output_fd;

static bool transfer(int fd, void *buffer, size_t length, bool writing)
{
	uint8_t *p = buffer;
	while (length)
	{
		ssize_t n = writing ? write(fd, p, length) : read(fd, p, length);
		if (n <= 0) return false;
		p += n;
		length -= n;
	}
	return true;
}

bool macsend_preinit(void) { return true; }
void macsend_cleanup(void) {}

bool macsend_packet(sa_family_t family, const void *packet, size_t length)
{
	uint32_t size = htonl(length);
	return transfer(output_fd, &size, sizeof(size), true) &&
		transfer(output_fd, (void *)packet, length, true);
}

int macos_utun_open(char *ifname, unsigned long ifname_size)
{
	uint32_t size;
	uint8_t packet[65536] __attribute__((aligned));
	while (transfer(STDIN_FILENO, &size, sizeof(size), false))
	{
		size_t length = ntohl(size);
		if (length > sizeof(packet) || !transfer(STDIN_FILENO, packet, length, false)) exit(2);
		uint32_t mark = 0;
		uint8_t verdict = processPacketData(&mark, "utun-test", "en-test", packet, &length);
		if ((verdict & VERDICT_MASK) != VERDICT_DROP)
		{
			struct sockaddr_storage dst;
			memset(&dst, 0, sizeof(dst));
			if (packet[0] >> 4 == 4)
				extract_endpoints((const struct ip *)packet, NULL, NULL, NULL, NULL, &dst);
			else
				extract_endpoints(NULL, (const struct ip6_hdr *)packet, NULL, NULL, NULL, &dst);
			if (!rawsend((const struct sockaddr *)&dst, mark, "en-test", packet, length)) exit(2);
		}
		size = 0;
		if (!transfer(output_fd, &size, sizeof(size), true)) exit(2);
	}
	cleanup_params(&params);
	exit(0);
}

int main(int argc, char **argv)
{
	output_fd = dup(STDOUT_FILENO);
	if (output_fd < 0 || dup2(STDERR_FILENO, STDOUT_FILENO) < 0) return 2;
	return engine_main(argc, argv);
}
