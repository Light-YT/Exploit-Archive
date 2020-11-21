#include <CommonCrypto/CommonDigest.h>
#include <mach-o/loader.h>
#include <mach-o/dyld_images.h>
#include <mach-o/fat.h>
#include <mach-o/swap.h>
#include <sys/stat.h>
#include <sys/event.h>
#include <dlfcn.h>
#include <pthread.h>
#include <sys/spawn.h>
#include <sys/mman.h>
#include <stdlib.h>
#include <fcntl.h>
#include <errno.h>

#include "kmem.h"
#include "cs_blobs.h"
#include "codesign.h"
#include "jailbreak.h"

#define ERROR(str, args...) LOG("ERROR: [%s] " str, __func__, ##args)
#define INFO(str, args...)  LOG("INFO: " str, ##args)

int inject_trust(const char *path) {
    LOG("signing %s...", path);
    
    if (access(path, F_OK) != 0)
    {
        LOG("you wanka, %s doesn't exist!", path);
        return -1;
    }
    
    FILE *fd = fopen(path, "r");
    if (fd == NULL)
    {
        LOG("failed to open file %s!", path);
        return -1;
    }
    
    int num_found_hashes = 0;
    void *hash_array = NULL;
    
    uint32_t magic;
    fread(&magic, sizeof(magic), 1, fd);
    fseek(fd, 0, SEEK_SET);
    
    int is_swap = (magic == MH_CIGAM  || magic == MH_CIGAM_64 ||
                   magic == FAT_CIGAM || magic == FAT_CIGAM_64);
    
    if (magic == MH_MAGIC || magic == MH_MAGIC_64 ||
        magic == MH_CIGAM || magic == MH_CIGAM_64)
    {
        // just single arch, just grab the hash
        fclose(fd);
        
        void *cd_hash = put_dick_in_macho(path, 0);
        
        if (cd_hash != NULL)
        {
            num_found_hashes++;
            hash_array = realloc(hash_array, num_found_hashes * CS_CDHASH_LEN);
            memcpy(hash_array + ((num_found_hashes - 1) * CS_CDHASH_LEN), cd_hash, CS_CDHASH_LEN);
        }
    }
    else if (magic == FAT_MAGIC || magic == FAT_MAGIC_64 ||
             magic == FAT_CIGAM || magic == FAT_CIGAM_64)
    {
        struct fat_header header;
        fread(&header, sizeof(header), 1, fd);
        if (is_swap) swap_fat_header(&header, 0);
        
        int arch_offset = sizeof(header);
        for (int i = 0; i < header.nfat_arch; i++)
        {
            struct fat_arch arch;
            fseek(fd, arch_offset, 0);
            fread(&arch, sizeof(struct fat_arch), 1, fd);
            if (is_swap) swap_fat_arch(&arch, 1, 0);
            
            fseek(fd, arch.offset, 0);
            
            uint32_t magic;
            fread(&magic, sizeof(magic), 1, fd);
            
            if (magic == MH_MAGIC || magic == MH_MAGIC_64 ||
                magic == MH_CIGAM || magic == MH_CIGAM_64)
            {
                void *cd_hash = put_dick_in_macho(path, arch.offset);
                
                if (cd_hash != NULL)
                {
                    num_found_hashes++;
                    hash_array = realloc(hash_array, num_found_hashes * CS_CDHASH_LEN);
                    memcpy(hash_array + ((num_found_hashes - 1) * CS_CDHASH_LEN), cd_hash, CS_CDHASH_LEN);
                }
            }
            
            arch_offset += sizeof(arch);
        }
        
        fclose(fd);
    }
    
    if (num_found_hashes == 0)
    {
        LOG("dood, we dinny find any hashes here :/ path: %s", path);
        return -1;
    }
    
    LOG("found %d hashes to inject", num_found_hashes);
    
    int total_hashes_size = num_found_hashes * sizeof(hash_t);
    int total_struct_size = sizeof(struct trust_chain) + total_hashes_size;
    struct trust_chain *chain_buf = (struct trust_chain *)malloc(total_struct_size);
    
    chain_buf->next = rk64(offs.data.trust_cache + kernel_slide);
    *(uint64_t *)&chain_buf->uuid[0] = 0xabadbabeabadbabe;
    *(uint64_t *)&chain_buf->uuid[8] = 0xabadbabeabadbabe;
    chain_buf->count = num_found_hashes;
    
    memcpy(chain_buf->hash, hash_array, total_hashes_size);
    
    for (int i = 0; i < num_found_hashes; i++)
    {
        char msg[(sizeof(hash_t) * 2) + 1];
        bzero(msg, sizeof(msg));
        
        char *ptr = msg;
        for (int j = 0; j < sizeof(hash_t); j += sizeof(uint32_t))
        {
            ptr += sprintf(ptr, "%x", ntohl(*(uint32_t *)&chain_buf->hash[i][j]));
        }
        LOG("got cdhash (%d): %s", i, msg);
    }
    
    uint64_t kernel_trust = kalloc(total_struct_size);
    kwrite(kernel_trust, chain_buf, total_struct_size);
    wk64(offs.data.trust_cache + kernel_slide, kernel_trust);
    
    free(hash_array);
    free(chain_buf);
    
    LOG("signed %s", path);
    return 0;
}

void *put_dick_in_macho(const char *path, uint64_t file_off)
{
    img_info_t img;
    img.name = path;
    img.file_off = file_off;
    
    if (open_img(&img) != 0)
    {
        LOG("failed to open file: %s", path);
        close_img(&img);
        return NULL;
    }
    
    uint32_t cs_length = 0;
    const uint8_t *cs = find_code_signature(&img, &cs_length);
    if (cs == NULL)
    {
        LOG("failed to find code signature: %s", path);
        close_img(&img);
        return NULL;
    }
    
    const CS_CodeDirectory *chosen_csdir = NULL;
    if (find_best_codedir(cs, cs_length, &chosen_csdir) != 0)
    {
        LOG("failed to find best csdir");
        close_img(&img);
        return NULL;
    }
    
    void *cd_hash = malloc(CS_CDHASH_LEN);
    if (hash_code_directory(chosen_csdir, cd_hash) != 0)
    {
        LOG("failed to hash code directory for file %s", path);
        close_img(&img);
        return NULL;
    }
    
    close_img(&img);
    return cd_hash;
}

// Finds the LC_CODE_SIGNATURE load command
const uint8_t *find_code_signature(img_info_t *info, uint32_t *cs_size) {
#define _LOG_ERROR(str, args...) ERROR("(%s) " str, info->name, ##args)
    if (info == NULL || info->addr == NULL) {
        return NULL;
    }
    
    // mach_header_64 is mach_header + reserved for padding
    const struct mach_header *mh = (const struct mach_header *)info->addr;
    
    uint32_t sizeofmh = 0;
    
    switch (mh->magic) {
        case MH_MAGIC_64:
            sizeofmh = sizeof(struct mach_header_64);
            break;
        case MH_MAGIC:
            sizeofmh = sizeof(struct mach_header);
            break;
        default:
            _LOG_ERROR("your magic is not valid in these lands: %08x", mh->magic);
            return NULL;
    }
    
    if (mh->sizeofcmds < mh->ncmds * sizeof(struct load_command)) {
        _LOG_ERROR("Corrupted macho (sizeofcmds < ncmds * sizeof(lc))");
        return NULL;
    }
    if (mh->sizeofcmds + sizeofmh > info->size) {
        _LOG_ERROR("Corrupted macho (sizeofcmds + sizeof(mh) > size)");
        return NULL;
    }
    
    const struct load_command *cmd = (const struct load_command *)((uintptr_t) info->addr + sizeofmh);
    for (int i = 0; i != mh->ncmds; ++i) {
        if (cmd->cmd == LC_CODE_SIGNATURE) {
            const struct linkedit_data_command* cscmd = (const struct linkedit_data_command*)cmd;
            if (cscmd->dataoff + cscmd->datasize > info->size) {
                _LOG_ERROR("Corrupted LC_CODE_SIGNATURE: dataoff + datasize > fsize");
                return NULL;
            }
            
            if (cs_size) {
                *cs_size = cscmd->datasize;
            }
            
            return (const uint8_t*)((uintptr_t)info->addr + cscmd->dataoff);
        }
        
        cmd = (const struct load_command *)((uintptr_t)cmd + cmd->cmdsize);
        if ((uintptr_t)cmd + sizeof(struct load_command) > (uintptr_t)info->addr + info->size) {
            _LOG_ERROR("Corrupted macho: Unexpected end of file while parsing load commands");
            return NULL;
        }
    }
    
    _LOG_ERROR("Didnt find the code signature");
    return NULL;
#undef _LOG_ERROR
}

#define BLOB_FITS(blob, size) ((size >= sizeof(*blob)) && (size >= ntohl(blob->length)))

// xnu-3789.70.16/bsd/kern/ubc_subr.c#470
int find_best_codedir(const void *csblob, uint32_t blob_size, const CS_CodeDirectory **chosen_cd) {
    *chosen_cd = NULL;
    
    const CS_GenericBlob *blob = (const CS_GenericBlob *)csblob;
    
    if (!BLOB_FITS(blob, blob_size)) {
        ERROR("csblob too small even for generic blob");
        return 1;
    }
    
    uint32_t length = ntohl(blob->length);
    
    if (ntohl(blob->magic) == CSMAGIC_EMBEDDED_SIGNATURE) {
        const CS_CodeDirectory *best_cd = NULL;
        int best_rank = 0;
        
        const CS_SuperBlob *sb = (const CS_SuperBlob *)csblob;
        uint32_t count = ntohl(sb->count);
        
        if (!BLOB_FITS(sb, blob_size)) {
            ERROR("csblob too small for superblob");
            return 1;
        }
        
        for (int n = 0; n < count; n++){
            const CS_BlobIndex *blobIndex = &sb->index[n];
            
            uint32_t type = ntohl(blobIndex->type);
            uint32_t offset = ntohl(blobIndex->offset);
            
            if (length < offset) {
                ERROR("offset of blob #%d overflows superblob length", n);
                return 1;
            }
            
            const CS_GenericBlob *subBlob = (const CS_GenericBlob *)((uintptr_t)csblob + offset);
            
            if (type == CSSLOT_CODEDIRECTORY || (type >= CSSLOT_ALTERNATE_CODEDIRECTORIES && type < CSSLOT_ALTERNATE_CODEDIRECTORY_LIMIT)) {
                const CS_CodeDirectory *candidate = (const CS_CodeDirectory *)subBlob;
                
                unsigned int rank = hash_rank(candidate);
                
                if (best_cd == NULL || rank > best_rank) {
                    best_cd = candidate;
                    best_rank = rank;
                    
                    *chosen_cd = best_cd;
                }
            }
        }
    } else if (ntohl(blob->magic) == CSMAGIC_CODEDIRECTORY) {
        *chosen_cd = (const CS_CodeDirectory *)blob;
    } else {
        ERROR("Unknown magic at csblob start: %08x", ntohl(blob->magic));
        return 1;
    }
    
    if (chosen_cd == NULL) {
        ERROR("didn't find codedirectory to hash");
        return 1;
    }
    
    return 0;
}

// xnu-3789.70.16/bsd/kern/ubc_subr.c#231
unsigned int hash_rank(const CS_CodeDirectory *cd) {
    uint32_t type = cd->hashType;
    
    for (unsigned int n = 0; n < sizeof(hashPriorities) / sizeof(hashPriorities[0]); ++n) {
        if (hashPriorities[n] == type) {
            return n + 1;
        }
    }
    
    return 0;
}

int hash_code_directory(const CS_CodeDirectory *directory, uint8_t hash[CS_CDHASH_LEN]) {
    uint32_t realsize = ntohl(directory->length);
    
    if (ntohl(directory->magic) != CSMAGIC_CODEDIRECTORY) {
        ERROR("expected CSMAGIC_CODEDIRECTORY");
        return 1;
    }
    
    uint8_t out[CS_HASH_MAX_SIZE];
    uint8_t hash_type = directory->hashType;
    
    switch (hash_type) {
        case CS_HASHTYPE_SHA1:
            CC_SHA1(directory, realsize, out);
            break;
            
        case CS_HASHTYPE_SHA256:
        case CS_HASHTYPE_SHA256_TRUNCATED:
            CC_SHA256(directory, realsize, out);
            break;
            
        case CS_HASHTYPE_SHA384:
            CC_SHA384(directory, realsize, out);
            break;
            
        default:
            INFO("Unknown hash type: 0x%x", hash_type);
            return 2;
    }
    
    memcpy(hash, out, CS_CDHASH_LEN);
    return 0;
}

const char *get_hash_name(uint8_t hash_type) {
    switch (hash_type) {
        case CS_HASHTYPE_SHA1:
            return "SHA1";
            
        case CS_HASHTYPE_SHA256:
        case CS_HASHTYPE_SHA256_TRUNCATED:
            return "SHA256";
            
        case CS_HASHTYPE_SHA384:
            return "SHA384";
            
        default:
            return "UNKNWON";
    }
    
    return "";
}

int open_img(img_info_t* info) {
#define _LOG_ERROR(str, args...) ERROR("(%s) " str, info->name, ##args)
    int ret = -1;
    
    if (info == NULL) {
        INFO("img info is NULL");
        return ret;
    }
    
    info->fd = -1;
    info->size = 0;
    info->addr = NULL;
    
    info->fd = open(info->name, O_RDONLY);
    if (info->fd == -1) {
        _LOG_ERROR("Couldn't open file");
        ret = 1;
        goto out;
    }
    
    struct stat s;
    if (fstat(info->fd, &s) != 0) {
        _LOG_ERROR("fstat: 0x%x (%s)", errno, strerror(errno));
        ret = 2;
        goto out;
    }
    
    size_t fsize = s.st_size;
    info->size = fsize - info->file_off;
    const void *map = mmap(NULL, fsize, PROT_READ, MAP_PRIVATE, info->fd, 0);
    
    if (map == MAP_FAILED) {
        _LOG_ERROR("mmap: 0x%x (%s)", errno, strerror(errno));
        ret = 4;
        goto out;
    }
    
    info->addr = (const void*) ((uintptr_t) map + info->file_off);
    ret = 0;
    
out:;
    if (ret) {
        close_img(info);
    }
    return ret;
    
#undef _LOG_ERROR
}

void close_img(img_info_t* info) {
    if (info == NULL) {
        return;
    }
    
    if (info->addr != NULL) {
        const void *map = (void*) ((uintptr_t) info->addr - info->file_off);
        size_t fsize = info->size + info->file_off;
        
        munmap((void*)map, fsize);
    }
    
    if (info->fd != -1) {
        close(info->fd);
    }
}
