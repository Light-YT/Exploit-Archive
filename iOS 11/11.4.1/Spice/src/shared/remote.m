#include <mach/mach.h>
#include <stdlib.h>
#include <dlfcn.h>

#include "common.h"
#include "remote.h"

// kern_return_t mach_vm_write(
//                             vm_map_t target_task,
//                             mach_vm_address_t address,
//                             vm_offset_t data,
//                             mach_msg_type_number_t dataCnt);

// kern_return_t mach_vm_read_overwrite(
//                                      vm_map_t target_task,
//                                      mach_vm_address_t address,
//                                      mach_vm_size_t size,
//                                      mach_vm_address_t data,
//                                      mach_vm_size_t *outsize);

// kern_return_t mach_vm_allocate(
//                                vm_map_t target,
//                                mach_vm_address_t *address,
//                                mach_vm_size_t size,
//                                int flags);

// kern_return_t mach_vm_deallocate(
//                                  vm_map_t target,
//                                  mach_vm_address_t address,
//                                  mach_vm_size_t size);

#define MAX_REMOTE_ARGS 8

extern void _pthread_set_self(pthread_t p);

uint64_t remote_alloc(mach_port_t task_port, uint64_t size)
{
    kern_return_t err;
    
    mach_vm_offset_t remote_addr = 0;
    mach_vm_size_t remote_size = (mach_vm_size_t)size;
    err = mach_vm_allocate(task_port, &remote_addr, remote_size, VM_FLAGS_ANYWHERE);
    if (err != KERN_SUCCESS){
        printf("unable to allocate buffer in remote process\n");
        return 0;
    }
    
    return (uint64_t)remote_addr;
}

void remote_free(mach_port_t task_port, uint64_t base, uint64_t size)
{
    kern_return_t err;
    
    err = mach_vm_deallocate(task_port, (mach_vm_address_t)base, (mach_vm_size_t)size);
    if (err !=  KERN_SUCCESS){
        printf("unabble to deallocate remote buffer\n");
        return;
    }
}

uint64_t alloc_and_fill_remote_buffer(mach_port_t task_port,
                                      uint64_t local_address,
                                      uint64_t length)
{
    kern_return_t err;
    
    uint64_t remote_address = remote_alloc(task_port, length);
    
    err = mach_vm_write(task_port, remote_address, (mach_vm_offset_t)local_address, (mach_msg_type_number_t)length);
    if (err != KERN_SUCCESS){
        printf("unable to write to remote memory \n");
        return 0;
    }
    
    return remote_address;
}

void remote_read_overwrite(mach_port_t task_port,
                           uint64_t remote_address,
                           uint64_t local_address,
                           uint64_t length) {
    kern_return_t err;
    
    mach_vm_size_t outsize = 0;
    err = mach_vm_read_overwrite(task_port, (mach_vm_address_t)remote_address, (mach_vm_size_t)length, (mach_vm_address_t)local_address, &outsize);
    if (err != KERN_SUCCESS){
        printf("remote read failed\n");
        return;
    }
    
    if (outsize != length){
        printf("remote read was short (expected %llx, got %llx\n", length, outsize);
        return;
    }
}

uint64_t find_gadget_candidate(char** alternatives, size_t gadget_length) {
    void* haystack_start = (void*)atoi;    // will do...
    size_t haystack_size = 100*1024*1024; // likewise...
    
    for (char* candidate = *alternatives; candidate != NULL; alternatives++) {
        void* found_at = memmem(haystack_start, haystack_size, candidate, gadget_length);
        if (found_at != NULL) {
            return (uint64_t)found_at;
        }
    }
    
    return 0;
}

uint64_t blr_x19_addr = 0;
uint64_t find_blr_x19_gadget() {
    if (blr_x19_addr != 0) {
        return blr_x19_addr;
    }
    
    char* blr_x19 = "\x60\x02\x3f\xd6";
    char* candidates[] = {blr_x19, NULL};
    blr_x19_addr = find_gadget_candidate(candidates, 4);
    return blr_x19_addr;
}

uint64_t call_remote(mach_port_t task_port, void* fptr, int n_params, ...)
{
    if (n_params > MAX_REMOTE_ARGS || n_params < 0){
        printf("unsupported number of arguments to remote function (%d)\n", n_params);
        return 0;
    }
    
    kern_return_t err;
    
    uint64_t remote_stack_base = 0;
    uint64_t remote_stack_size = 4*1024*1024;
    
    remote_stack_base = remote_alloc(task_port, remote_stack_size);
    
    uint64_t remote_stack_middle = remote_stack_base + (remote_stack_size/2);
    
    // create a new thread in the target
    // just using the mach thread API doesn't initialize the pthread thread-local-storage
    // which means that stuff which relies on that will crash
    // we can sort-of make that work by calling _pthread_set_self(NULL) in the target process
    // which will give the newly created thread the same TLS region as the main thread

    _STRUCT_ARM_THREAD_STATE64 thread_state;
    bzero(&thread_state, sizeof(thread_state));
    
    mach_msg_type_number_t thread_stateCnt = sizeof(thread_state)/4;
    
    // we'll start the thread running and call _pthread_set_self first:
    thread_state.__sp = remote_stack_middle;
    thread_state.__pc = (uint64_t)_pthread_set_self;
    
    // set these up to put us into a predictable state we can monitor for:
    uint64_t loop_lr = find_blr_x19_gadget();
    thread_state.__x[19] = loop_lr;
    thread_state.__lr = loop_lr;
    
    // set the argument to NULL:
    thread_state.__x[0] = 0;
    
    mach_port_t thread_port = MACH_PORT_NULL;
    
    err = thread_create_running(task_port, ARM_THREAD_STATE64, (thread_state_t)&thread_state, thread_stateCnt, &thread_port);
    if (err != KERN_SUCCESS){
        printf("error creating thread in child: %s\n", mach_error_string(err));
        return 0;
    }
    // NSLog(@"new thread running in child: %x\n", thread_port);
    
    // wait for it to hit the loop:
    while(1)
    {
        // monitor the thread until we see it's in the infinite loop indicating it's done:
        err = thread_get_state(thread_port, ARM_THREAD_STATE64, (thread_state_t)&thread_state, &thread_stateCnt);
        if (err != KERN_SUCCESS)
        {
            printf("error getting thread state: %s\n", mach_error_string(err));
            return 0;
        }
        
        if (thread_state.__pc == loop_lr && thread_state.__x[19] == loop_lr)
        {
            // thread has returned from the target function
            break;
        }
    }
    
    // the thread should now have pthread local storage
    // pause it:
    
    err = thread_suspend(thread_port);
    if (err != KERN_SUCCESS){
        printf("unable to suspend target thread\n");
        return 0;
    }
    
    /*
     err = thread_abort(thread_port);
     if (err != KERN_SUCCESS){
     NSLog(@"unable to get thread out of any traps\n");
     return 0;
     }
     */
    
    // set up for the actual target call:
    thread_state.__sp = remote_stack_middle;
    thread_state.__pc = (uint64_t)fptr;
    
    // set these up to put us into a predictable state we can monitor for:
    thread_state.__x[19] = loop_lr;
    thread_state.__lr = loop_lr;
    
    va_list ap;
    va_start(ap, n_params);
    
    arg_desc *args[MAX_REMOTE_ARGS] = {0};
    
    uint64_t remote_buffers[MAX_REMOTE_ARGS] = {0};
    //uint64_t remote_buffer_sizes[MAX_REMOTE_ARGS] = {0};
    
    for (int i = 0; i < n_params; i++){
        arg_desc* arg = va_arg(ap, arg_desc*);
        
        args[i] = arg;
        
        switch(arg->type){
            case ARG_LITERAL:
            {
                thread_state.__x[i] = arg->value;
                break;
            }
                
            case ARG_BUFFER:
            case ARG_BUFFER_PERSISTENT:
            case ARG_INOUT_BUFFER:
            {
                uint64_t remote_buffer = alloc_and_fill_remote_buffer(task_port, arg->value, arg->length);
                remote_buffers[i] = remote_buffer;
                thread_state.__x[i] = remote_buffer;
                break;
            }
                
            case ARG_OUT_BUFFER:
            {
                uint64_t remote_buffer = remote_alloc(task_port, arg->length);
                // NSLog(@"allocated a remote out buffer: %llx\n", remote_buffer);
                remote_buffers[i] = remote_buffer;
                thread_state.__x[i] = remote_buffer;
                break;
            }
                
            default:
            {
                printf("invalid argument type!\n");
            }
        }
    }
    
    va_end(ap);
    
    err = thread_set_state(thread_port, ARM_THREAD_STATE64, (thread_state_t)&thread_state, thread_stateCnt);
    if (err != KERN_SUCCESS)
    {
        printf("error setting new thread state: %s\n", mach_error_string(err));
        return 0;
    }
    // NSLog(@"thread state updated in target: %x\n", thread_port);
    
    err = thread_resume(thread_port);
    if (err != KERN_SUCCESS)
    {
        printf("unable to resume target thread\n");
        return 0;
    }
    
    while(1){
        // monitor the thread until we see it's in the infinite loop indicating it's done:
        err = thread_get_state(thread_port, ARM_THREAD_STATE64, (thread_state_t)&thread_state, &thread_stateCnt);
        if (err != KERN_SUCCESS)
        {
            printf("error getting thread state: %s\n", mach_error_string(err));
            return 0;
        }
        
        if (thread_state.__pc == loop_lr/*&& thread_state.__x[19] == loop_lr*/){
            // thread has returned from the target function
            break;
        }
        
        // thread isn't in the infinite loop yet, let it continue
    }
    
    // deallocate the remote thread
    err = thread_terminate(thread_port);
    if (err != KERN_SUCCESS){
        printf("failed to terminate thread\n");
        return 0;
    }
    mach_port_deallocate(mach_task_self(), thread_port);
    
    // handle post-call argument cleanup/copying:
    for (int i = 0; i < MAX_REMOTE_ARGS; i++){
        arg_desc *arg = args[i];
        if (arg == NULL){
            break;
        }
        switch (arg->type){
            case ARG_BUFFER:
            {
                remote_free(task_port, remote_buffers[i], arg->length);
                break;
            }
                
            case ARG_INOUT_BUFFER:
            case ARG_OUT_BUFFER:
            {
                // copy the contents back:
                remote_read_overwrite(task_port, remote_buffers[i], arg->value, arg->length);
                remote_free(task_port, remote_buffers[i], arg->length);
                break;
            }
        }
    }
    
    uint64_t ret_val = thread_state.__x[0];
    
    // NSLog(@"remote function call return value: %llx\n", ret_val);
    
    // deallocate the stack in the target:
    remote_free(task_port, remote_stack_base, remote_stack_size);
    
    return ret_val;
}

int inject_library(pid_t pid, const char *path)
{
    mach_port_t task_port;
    kern_return_t ret = task_for_pid(mach_task_self(), pid, &task_port);
    
    if (ret != KERN_SUCCESS || task_port == MACH_PORT_NULL)
    {
        printf("failed to get task for pid %d (%x - %s)\n", pid, ret, mach_error_string(ret));
        return ret;
    }
    
    printf("got task port: %x\n", task_port);
    
    call_remote(task_port, dlopen, 2, REMOTE_CSTRING(path), REMOTE_LITERAL(RTLD_NOW));
    
    return 0;
}