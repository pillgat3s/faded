// Faded-Bridging-Header.h — exposes the driver's shared-memory layout to Swift.
//
// FadedShared.h is the single source of truth for the ring's memory layout and
// is compiled into the driver as C++ and imported here as C. Keeping one header
// rather than mirroring the struct in Swift means the two ends cannot silently
// disagree about offsets.
#import "FadedShared.h"

#import <fcntl.h>
#import <sys/mman.h>

/// `shm_open` is variadic, which Swift refuses to import. Wrapping it here also
/// keeps the object's name in one place — the header the driver already owns.
static inline int FadedSharedRingOpenReadOnly(void)
{
    return shm_open(kFadedShmName, O_RDONLY);
}
