#ifndef _RAR_CRC_
#define _RAR_CRC_

// This function is only to intialize external CRC tables. We do not need to
// call it before calculating CRC32.
void InitCRC32(uint *CRCTab);

uint CRC32(uint StartCRC,const void *Addr,size_t Size);

#ifdef CRCMT_DIAG
// Which CRC32 implementation detection actually selected, for crcmt/'s
// benchmark labels. Guessing it from CPUID in a shell script got it wrong on a
// part with PCLMULQDQ but no VPCLMULQDQ, which is the one case that most needed
// labelling correctly - so the binary reports it instead.
const char *CRC32ActivePath();
#endif

#ifndef SFX_MODULE
ushort Checksum14(ushort StartCRC,const void *Addr,size_t Size);
#endif


#endif
