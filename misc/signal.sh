#!/bin/sh

#
# Copyright (c) 2013 EMC Corp.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
# $FreeBSD$
#

# Regression test for kern/150138: signal sent to stopped, traced process
# not immediately handled on continue.
# Fixed in r212047.

# Test scenario by Dan McNulty <dkmcnulty gmail.com>

cat > waitthread.c <<EOF
#include <unistd.h>
#include <stdlib.h>
#include <pthread.h>
#include <stdio.h>
#include <assert.h>
#include <signal.h>
#include <time.h>
#include <sys/syscall.h>
#include <string.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <errno.h>

struct threadArg {
    int id;
    pthread_mutex_t *mutex;
};

void *entry(void *arg) {
    struct threadArg *thisArg = (struct threadArg *)arg;

    long lwp_id = thisArg->id;
    if( syscall(SYS_thr_self, &lwp_id) ) {
        perror("syscall");
    }

    printf("%ld waiting on lock\n", lwp_id);

    if( pthread_mutex_lock(thisArg->mutex) != 0 ) {
        perror("pthread_mutex_lock");
        return NULL;
    }

    printf("%ld obtained lock\n", lwp_id);

    if( pthread_mutex_unlock(thisArg->mutex) != 0 ) {
        perror("pthread_mutex_unlock");
        return NULL;
    }

    printf("%ld released lock\n", lwp_id);

    return NULL;
}

int main(int argc, char **argv) {
    if( 2 != argc ) {
        printf("Usage: %s <num. of threads>\n", argv[0]);
        return EXIT_FAILURE;
    }

    printf("%d\n", getpid());

    int numThreads;
    sscanf(argv[1], "%d", &numThreads);
    if( numThreads < 1 ) numThreads = 1;

    pthread_t *threads = (pthread_t *)malloc(sizeof(pthread_t)*numThreads);

    pthread_mutex_t *mutex = (pthread_mutex_t *)malloc(sizeof(pthread_mutex_t));

    if( pthread_mutex_init(mutex, NULL) != 0 ) {
        perror("pthread_mutex_init");
        return EXIT_FAILURE;
    }

    if( pthread_mutex_lock(mutex) != 0 ) {
        perror("pthread_mutex_lock");
        return EXIT_FAILURE;
    }

    int i;
    for(i = 0; i < numThreads; ++i) {
        struct threadArg *arg = (struct threadArg *)malloc(sizeof(struct threadArg));
        arg->id = i;
        arg->mutex = mutex;
        assert( !pthread_create(&threads[i], NULL, &entry, (void *)arg) );
    }

    // Wait on the named pipe
    unlink("/tmp/waitthread");
    if( mkfifo("/tmp/waitthread", S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP) ) {
        perror("mkfifo");
        return EXIT_FAILURE;
    }

    FILE *fifo;
    do {
        if( (fifo = fopen("/tmp/waitthread", "r")) == NULL ) {
            if( errno == EINTR ) continue;

            perror("fopen");
            return EXIT_FAILURE;
        }
        break;
    }while(1);

    unsigned char byte;
    if( fread(&byte, sizeof(unsigned char), 1, fifo) != 1 ) {
        perror("fread");
    }

    fclose(fifo);

    unlink("/tmp/waitthread");

    printf("Received notification\n");

    if( pthread_mutex_unlock(mutex) != 0 ) {
        perror("pthread_mutex_unlock");
        return EXIT_FAILURE;
    }

    printf("Unlocked mutex, joining\n");

    for(i = 0; i < numThreads; ++i ) {
        assert( !pthread_join(threads[i], NULL) );
    }

    return EXIT_SUCCESS;
}
EOF
cat > tkill.c <<EOF
#include <sys/syscall.h>
#include <unistd.h>
#include <stdio.h>
#include <errno.h>
#include <stdlib.h>
#include <signal.h>

int main(int argc, char *argv[]) {
    if( argc != 4 ) {
        printf("Usage: %s <pid> <lwp_id> <sig>\n", argv[0]);
        return EXIT_FAILURE;
    }

    pid_t pid;
    sscanf(argv[1], "%d", &pid);

    long id;
    sscanf(argv[2], "%ld", &id);

    int sig;
    sscanf(argv[3], "%d", &sig);
    
    if( syscall(SYS_thr_kill2, pid, id, sig) ) {
        perror("syscall");
    }

    return EXIT_SUCCESS;
}
EOF
cc -o waitthread -Wall -Wextra waitthread.c -lpthread || exit
cc -o tkill -Wall -Wextra tkill.c || exit
rm -f waitthread.c tkill.c

rm -f gdbfifo gdbout pstat
mkfifo gdbfifo
sleep 300 > gdbfifo &	# Keep the fifo open
fifopid=$!

gdb ./waitthread < gdbfifo > gdbout 2>&1 &
echo "set args 8" > gdbfifo
echo "run"        > gdbfifo
sleep .2

pid=`ps | grep -v grep | grep "waitthread 8" | sed 's/ .*//'`
procstat -t $pid > pstat

t1=`grep fifo  pstat | awk '{print $2}'`
t2=`grep umtxn pstat | awk '{print $2}' | tail -1`

./tkill $pid $t1 5	# SIGTRAP
./tkill $pid $t2 2	# SIGINT

echo "c"    > gdbfifo
echo "quit" > gdbfifo

kill $fifopid

if grep -q "signal SIGINT" gdbout; then
	rm -f gdbfifo gdbout pstat waitthread tkill
else
	echo FAIL
fi