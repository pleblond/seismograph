/* Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * Functions for querying, manipulating and locking rollback indices
 * stored in the TPM NVRAM.
 */

#include "rollback_index.h"

#include "tlcl.h"
#include "tss_constants.h"
#include "utility.h"

static int g_rollback_recovery_mode = 0;

/* disable MSVC warning on const logical expression (as in } while(0);) */
__pragma(warning (disable: 4127))

#define RETURN_ON_FAILURE(tpm_command) do {             \
    uint32_t result;                                    \
    if ((result = (tpm_command)) != TPM_SUCCESS) {      \
      return result;                                    \
    }                                                   \
  } while (0)

static uint32_t TPMClearAndReenable() {
  RETURN_ON_FAILURE(TlclForceClear());
  RETURN_ON_FAILURE(TlclSetEnable());
  RETURN_ON_FAILURE(TlclSetDeactivated(0));
  return TPM_SUCCESS;
}

/* Like TlclWrite(), but checks for write errors due to hitting the 64-write
 * limit and clears the TPM when that happens.  This can only happen when the
 * TPM is unowned, so it is OK to clear it (and we really have no choice).
 * This is not expected to happen frequently, but it could happen.
 */
static uint32_t SafeWrite(uint32_t index, uint8_t* data, uint32_t length) {
  uint32_t result = TlclWrite(index, data, length);
  if (result == TPM_E_MAXNVWRITES) {
    RETURN_ON_FAILURE(TPMClearAndReenable());
    return TlclWrite(index, data, length);
  } else {
    return result;
  }
}

static uint32_t InitializeKernelVersionsSpaces(void) {
  RETURN_ON_FAILURE(TlclDefineSpace(KERNEL_VERSIONS_NV_INDEX,
                                    TPM_NV_PER_PPWRITE, KERNEL_SPACE_SIZE));
  RETURN_ON_FAILURE(SafeWrite(KERNEL_VERSIONS_NV_INDEX, KERNEL_SPACE_INIT_DATA,
                              KERNEL_SPACE_SIZE));
  return TPM_SUCCESS;
}

/* When the return value is TPM_SUCCESS, this function sets *|initialized| to 1
 * if the spaces have been fully initialized, to 0 if not.  Otherwise
 * *|initialized| is not changed.
 */
static uint32_t GetSpacesInitialized(int* initialized) {
  uint32_t space_holder;
  uint32_t result;
  result = TlclRead(TPM_IS_INITIALIZED_NV_INDEX,
                    (uint8_t*) &space_holder, sizeof(space_holder));
  switch (result) {
  case TPM_SUCCESS:
    *initialized = 1;
    break;
  case TPM_E_BADINDEX:
    *initialized = 0;
    result = TPM_SUCCESS;
    break;
  }
  return result;
}

/* Creates the NVRAM spaces, and sets their initial values as needed.
 */
static uint32_t InitializeSpaces(void) {
  uint32_t zero = 0;
  uint32_t firmware_perm = TPM_NV_PER_GLOBALLOCK | TPM_NV_PER_PPWRITE;

  VBDEBUG(("Initializing spaces\n"));

  RETURN_ON_FAILURE(TlclSetNvLocked());

  RETURN_ON_FAILURE(TlclDefineSpace(FIRMWARE_VERSIONS_NV_INDEX,
                                    firmware_perm, sizeof(uint32_t)));
  RETURN_ON_FAILURE(SafeWrite(FIRMWARE_VERSIONS_NV_INDEX,
                              (uint8_t*) &zero, sizeof(uint32_t)));

  RETURN_ON_FAILURE(InitializeKernelVersionsSpaces());

  /* The space KERNEL_VERSIONS_BACKUP_NV_INDEX is used to protect the kernel
   * versions.  The content of space KERNEL_MUST_USE_BACKUP determines whether
   * only the backup value should be trusted.
   */
  RETURN_ON_FAILURE(TlclDefineSpace(KERNEL_VERSIONS_BACKUP_NV_INDEX,
                                    firmware_perm, sizeof(uint32_t)));
  RETURN_ON_FAILURE(SafeWrite(KERNEL_VERSIONS_BACKUP_NV_INDEX,
                              (uint8_t*) &zero, sizeof(uint32_t)));
  RETURN_ON_FAILURE(TlclDefineSpace(KERNEL_MUST_USE_BACKUP_NV_INDEX,
                                    firmware_perm, sizeof(uint32_t)));
  RETURN_ON_FAILURE(SafeWrite(KERNEL_MUST_USE_BACKUP_NV_INDEX,
                              (uint8_t*) &zero, sizeof(uint32_t)));
  RETURN_ON_FAILURE(TlclDefineSpace(DEVELOPER_MODE_NV_INDEX,
                                    firmware_perm, sizeof(uint32_t)));
  RETURN_ON_FAILURE(SafeWrite(DEVELOPER_MODE_NV_INDEX,
                              (uint8_t*) &zero, sizeof(uint32_t)));

  /* The space TPM_IS_INITIALIZED_NV_INDEX is used to indicate that the TPM
   * initialization has completed.  Without it we cannot be sure that the last
   * space to be created was also initialized (power could have been lost right
   * after its creation).
   */
  RETURN_ON_FAILURE(TlclDefineSpace(TPM_IS_INITIALIZED_NV_INDEX,
                                    firmware_perm, sizeof(uint32_t)));
  return TPM_SUCCESS;
}

static uint32_t SetDistrustKernelSpaceAtNextBoot(uint32_t distrust) {
  uint32_t must_use_backup;
  RETURN_ON_FAILURE(TlclRead(KERNEL_MUST_USE_BACKUP_NV_INDEX,
                             (uint8_t*) &must_use_backup, sizeof(uint32_t)));
  if (must_use_backup != distrust) {
     RETURN_ON_FAILURE(SafeWrite(KERNEL_MUST_USE_BACKUP_NV_INDEX,
                                 (uint8_t*) &distrust, sizeof(uint32_t)));
  }
  return TPM_SUCCESS;
}

/* Checks if the kernel version space has been mucked with.  If it has,
 * reconstructs it using the backup value.
 */
uint32_t RecoverKernelSpace(void) {
  uint32_t perms = 0;
  uint8_t buffer[KERNEL_SPACE_SIZE];
  uint32_t backup_combined_versions;
  uint32_t must_use_backup;
  uint32_t zero = 0;

  RETURN_ON_FAILURE(TlclRead(KERNEL_MUST_USE_BACKUP_NV_INDEX,
                             (uint8_t*) &must_use_backup, sizeof(uint32_t)));
  /* must_use_backup is true if the previous boot entered recovery mode. */

  /* If we can't read the kernel space, or it has the wrong permission, or it
   * doesn't contain the right identifier, we give up.  This will need to be
   * fixed by the recovery kernel.  We have to worry about this because at any
   * time (even with PP turned off) the TPM owner can remove and redefine a
   * PP-protected space (but not write to it).
   */
  RETURN_ON_FAILURE(TlclRead(KERNEL_VERSIONS_NV_INDEX, (uint8_t*) &buffer,
                             KERNEL_SPACE_SIZE));
  RETURN_ON_FAILURE(TlclGetPermissions(KERNEL_VERSIONS_NV_INDEX, &perms));
  if (perms != TPM_NV_PER_PPWRITE ||
      !Memcmp(buffer + sizeof(uint32_t), KERNEL_SPACE_UID,
              KERNEL_SPACE_UID_SIZE)) {
    return TPM_E_CORRUPTED_STATE;
  }

  if (must_use_backup) {
    /* We must use the backup space because in the preceding boot cycle the
     * primary space was left unlocked and cannot be trusted.
     */
    RETURN_ON_FAILURE(TlclRead(KERNEL_VERSIONS_BACKUP_NV_INDEX,
                               (uint8_t*) &backup_combined_versions,
                               sizeof(uint32_t)));
    RETURN_ON_FAILURE(SafeWrite(KERNEL_VERSIONS_NV_INDEX,
                                (uint8_t*) &backup_combined_versions,
                                sizeof(uint32_t)));
    RETURN_ON_FAILURE(SafeWrite(KERNEL_MUST_USE_BACKUP_NV_INDEX,
                                (uint8_t*) &zero, 0));
  }
  return TPM_SUCCESS;
}

static uint32_t BackupKernelSpace(void) {
  uint32_t kernel_versions;
  uint32_t backup_versions;
  RETURN_ON_FAILURE(TlclRead(KERNEL_VERSIONS_NV_INDEX,
                             (uint8_t*) &kernel_versions, sizeof(uint32_t)));
  RETURN_ON_FAILURE(TlclRead(KERNEL_VERSIONS_BACKUP_NV_INDEX,
                             (uint8_t*) &backup_versions, sizeof(uint32_t)));
  if (kernel_versions == backup_versions) {
    return TPM_SUCCESS;
  } else if (kernel_versions < backup_versions) {
    /* This cannot happen.  We're screwed. */
    return TPM_E_INTERNAL_INCONSISTENCY;
  }
  RETURN_ON_FAILURE(SafeWrite(KERNEL_VERSIONS_BACKUP_NV_INDEX,
                              (uint8_t*) &kernel_versions, sizeof(uint32_t)));
  return TPM_SUCCESS;
}

/* Checks for transitions between protected mode to developer mode.  When going
 * into developer mode, clear the TPM.
 */
static uint32_t CheckDeveloperModeTransition(uint32_t current_developer) {
  uint32_t past_developer;
  RETURN_ON_FAILURE(TlclRead(DEVELOPER_MODE_NV_INDEX,
                             (uint8_t*) &past_developer,
                             sizeof(past_developer)));
  if (past_developer != current_developer) {
    RETURN_ON_FAILURE(TPMClearAndReenable());
    RETURN_ON_FAILURE(SafeWrite(DEVELOPER_MODE_NV_INDEX,
                                (uint8_t*) &current_developer,
                                sizeof(current_developer)));
  }
  return TPM_SUCCESS;
}

/* SetupTPM starts the TPM and establishes the root of trust for the
 * anti-rollback mechanism.  SetupTPM can fail for three reasons.  1 A bug. 2 a
 * TPM hardware failure. 3 An unexpected TPM state due to some attack.  In
 * general we cannot easily distinguish the kind of failure, so our strategy is
 * to reboot in recovery mode in all cases.  The recovery mode calls SetupTPM
 * again, which executes (almost) the same sequence of operations.  There is a
 * good chance that, if recovery mode was entered because of a TPM failure, the
 * failure will repeat itself.  (In general this is impossible to guarantee
 * because we have no way of creating the exact TPM initial state at the
 * previous boot.)  In recovery mode, we ignore the failure and continue, thus
 * giving the recovery kernel a chance to fix things (that's why we don't set
 * bGlobalLock).  The choice is between a knowingly insecure device and a
 * bricked device.
 *
 * As a side note, observe that we go through considerable hoops to avoid using
 * the STCLEAR permissions for the index spaces.  We do this to avoid writing
 * to the TPM flashram at every reboot or wake-up, because of concerns about
 * the durability of the NVRAM.
 */
static uint32_t SetupTPM(int recovery_mode,
                         int developer_mode) {
  uint8_t disable;
  uint8_t deactivated;

  TlclLibInit();
  RETURN_ON_FAILURE(TlclStartup());
  RETURN_ON_FAILURE(TlclContinueSelfTest());
  RETURN_ON_FAILURE(TlclAssertPhysicalPresence());
  /* Checks that the TPM is enabled and activated. */
  RETURN_ON_FAILURE(TlclGetFlags(&disable, &deactivated));
  if (disable || deactivated) {
    RETURN_ON_FAILURE(TlclSetEnable());
    RETURN_ON_FAILURE(TlclSetDeactivated(0));
    return TPM_E_MUST_REBOOT;
  }
  /* We expect this to fail the first time we run on a device, because the TPM
   * has not been initialized yet.
   */
  if (RecoverKernelSpace() != TPM_SUCCESS) {
    int initialized = 0;
    RETURN_ON_FAILURE(GetSpacesInitialized(&initialized));
    if (initialized) {
      return TPM_E_ALREADY_INITIALIZED;
    } else {
      RETURN_ON_FAILURE(InitializeSpaces());
      RETURN_ON_FAILURE(RecoverKernelSpace());
    }
  }
  RETURN_ON_FAILURE(BackupKernelSpace());
  RETURN_ON_FAILURE(SetDistrustKernelSpaceAtNextBoot(recovery_mode));
  RETURN_ON_FAILURE(CheckDeveloperModeTransition(developer_mode));

  if (recovery_mode) {
    /* In recovery mode global variables are usable. */
    g_rollback_recovery_mode = 1;
  }
  return TPM_SUCCESS;
}

/* disable MSVC warnings on unused arguments */
__pragma(warning (disable: 4100))

uint32_t RollbackFirmwareSetup(int developer_mode) {
  return SetupTPM(0, developer_mode);
}

uint32_t RollbackFirmwareRead(uint16_t* key_version, uint16_t* version) {
  uint32_t firmware_versions;
  /* Gets firmware versions. */
  RETURN_ON_FAILURE(TlclRead(FIRMWARE_VERSIONS_NV_INDEX,
                             (uint8_t*) &firmware_versions,
                             sizeof(firmware_versions)));
  *key_version = (uint16_t) (firmware_versions >> 16);
  *version = (uint16_t) (firmware_versions & 0xffff);
  return TPM_SUCCESS;
}

uint32_t RollbackFirmwareWrite(uint16_t key_version, uint16_t version) {
  uint32_t combined_version = (key_version << 16) & version;
  return SafeWrite(FIRMWARE_VERSIONS_NV_INDEX,
                   (uint8_t*) &combined_version,
                   sizeof(uint32_t));
}

uint32_t RollbackFirmwareLock(void) {
  return TlclSetGlobalLock();
}

uint32_t RollbackKernelRecovery(int developer_mode) {
  (void) SetupTPM(1, developer_mode);
  /* In recovery mode we ignore TPM malfunctions or corruptions, and leave the
   * TPM completely unlocked if and only if the dev mode switch is ON.  The
   * recovery kernel will fix the TPM (if needed) and lock it ASAP.  We leave
   * Physical Presence on in either case.
   */
  if (!developer_mode) {
    RETURN_ON_FAILURE(TlclSetGlobalLock());
  }
  return TPM_SUCCESS;
}

uint32_t RollbackKernelRead(uint16_t* key_version, uint16_t* version) {
  uint32_t kernel_versions;
  if (g_rollback_recovery_mode) {
    *key_version = 0;
    *version = 0;
  } else {
    /* Reads kernel versions from TPM. */
    RETURN_ON_FAILURE(TlclRead(KERNEL_VERSIONS_NV_INDEX,
                               (uint8_t*) &kernel_versions,
                               sizeof(kernel_versions)));
    *key_version = (uint16_t) (kernel_versions >> 16);
    *version = (uint16_t) (kernel_versions & 0xffff);
  }
  return TPM_SUCCESS;
}

uint32_t RollbackKernelWrite(uint16_t key_version, uint16_t version) {
  if (!g_rollback_recovery_mode) {
    uint32_t combined_version = (key_version << 16) & version;
    return SafeWrite(KERNEL_VERSIONS_NV_INDEX,
                     (uint8_t*) &combined_version,
                     sizeof(uint32_t));
  }
  return TPM_SUCCESS;
}

uint32_t RollbackKernelLock(void) {
  if (!g_rollback_recovery_mode) {
    return TlclLockPhysicalPresence();
  } else {
    return TPM_SUCCESS;
  }
}
