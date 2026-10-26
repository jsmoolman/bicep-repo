# Initialize-LimsGuestDataDisks.ps1 — design rationale, evidence, and Microsoft documentation citations

This document holds the extensive explanatory rationale, real-world evidence,
and Microsoft documentation citations that previously lived inline as large
comment blocks in `Initialize-LimsGuestDataDisks.ps1`. They were moved out of
the script to keep its total character count safely under Bicep's
`loadTextContent()` 131,072-character limit
(https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/bicep-functions-files#loadtextcontent)
— see the "Embedded-script size budget" section of `docs/operations.md` for
the project's own, smaller 100,000-character budget and the CI guard that
enforces it.

**This is a packaging change only.** No executable behavior, safety check,
fixed allowlist value, disk binding, parameter, execution mode, or resource
scope was altered when this content was extracted — see
`Initialize-LimsGuestDataDisks.Tests.ps1` and the semantic-token-stream
verification recorded in the commit that performed this extraction for the
evidence. The script itself still carries a short, concise comment at each
of the locations below, cross-referencing the matching heading in this file.

## Module header `.DESCRIPTION` — full safety model

Delivered inline via a `Microsoft.Compute/virtualMachines/runCommands`
resource (see `modules/compute/lims-ws2025-dev-foundation/main.bicep`) --
never from a storage account, never containing a secret.

SAFETY MODEL (see `docs/operations.md` for the full behavioral contract):

1) Independent fixed allowlist (`Get-ApprovedDiskPreparationAllowlist`). The
   exact approved subscription/resource-group/VM-name/computer-name/disk/LUN/
   size/drive-letter/label/allocation-unit combination for the APP and SQL
   targets is hardcoded in this script, independent of any caller-supplied
   parameter. Both the caller-supplied `-Expected*` parameters AND the live
   Azure Instance Metadata Service (IMDS) response are each independently
   required to match this fixed allowlist -- the two of them merely agreeing
   with EACH OTHER is not sufficient, since a misconfigured caller and a
   misdirected guest could in principle agree with each other while both
   being wrong.

2) Guest disk correlation that excludes the OS and temporary disks BEFORE
   resolving data disks (see `Select-NonOsNonTemporaryDiskCandidates`). The
   OS disk is excluded via the Windows Storage module's own documented
   IsBoot/IsSystem flags
   (https://learn.microsoft.com/en-us/powershell/module/storage/get-disk),
   never by a hardcoded disk number. The Azure temporary (resource) disk is
   NOT a managed disk
   (https://learn.microsoft.com/en-us/azure/virtual-machines/managed-disks-overview,
   "Temporary disk" -- "Most VMs contain a temporary disk, which isn't a
   managed disk") and therefore never appears in IMDS's
   `storageProfile.dataDisks[]` array, so it cannot be positively resolved by
   LUN the way a real data disk can. This script no longer infers the
   temporary disk's identity from guest-only topology (a previous version
   assumed every non-OS disk sharing the OS disk's SCSI bus/port was
   temporary storage, citing an unofficial, third-party source -- that
   assumption, and any hardcoded SCSI bus/port number, has been removed
   entirely). Instead it combines two independent, Microsoft-documented
   sources: the Azure platform's own authoritative report of this VM's
   temporary disk size (IMDS `compute.storageProfile.resourceDisk.size`, in
   kB --
   https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service,
   "Storage Profile", documented from api-version 2021-02-01) and each
   remaining candidate disk's own guest-reported size (`Get-Disk.Size`). A
   disk is only ever excluded as temporary storage when its size matches
   Azure's own independently reported temporary-disk size exactly (within
   reasonable rounding tolerance); any ambiguity -- ZERO candidates matching
   a nonzero platform-reported temporary-disk size, or MORE THAN ONE
   candidate matching -- any disk reporting missing/invalid SCSI addressing,
   and any failure of IMDS to report resourceDisk.size at all are each a hard
   failure for the whole plan -- never a silent guess, never a fallback to
   guest-only topology, and a "no match found" result is never treated as
   "no temporary disk is present."

   OBSERVED, CURRENTLY UNRESOLVED DISCREPANCY: on the two real LIMS WS2025
   DEV v2 VMs, IMDS's reported resourceDisk.size has been observed not to
   reconcile with the real, guest-observed ~150 GiB temporary disk under the
   documented unit interpretation or any other single-unit reinterpretation
   independently checked (see "`Get-ImdsResourceDiskSizeBytes` — IMDS
   `resourceDisk.size` discrepancy" below) -- this correctly blocks this
   identification path for those two VMs as observed to date. This is
   reported as an observation about these two specific VMs at the time they
   were inspected, not as a proven, permanent platform defect or as a
   characteristic established to apply to this VM size/generation in
   general -- no authoritative Microsoft source confirming either of those
   broader claims has been found; see the customer-attested guest-disk-
   UniqueId binding (point 2a below), now enabled for both real targets, as
   the reviewed path that identifies disks on these two VMs without
   depending on this discrepancy being resolved.

   Only after this exclusion are the remaining candidate disks correlated to
   an approved Azure LUN via the documented `Win32_DiskDrive.SCSILogicalUnit`
   property
   (https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-diskdrive),
   which Microsoft's own "How to map Azure Disks to Windows VM guest disks"
   guidance
   (https://learn.microsoft.com/en-us/azure/virtual-machines/windows/azure-to-guest-disk-mapping)
   identifies as the correct way to disambiguate same-size data disks. Disks
   are never selected by size alone, by picking the first LUN match, or by
   enumerating "all RAW disks" -- any remaining ambiguity (zero or more than
   one candidate at a given LUN) is a hard failure. Managed-disk capacity is
   compared against the guest's own `Get-Disk.Size` using a small, fixed,
   one-sided tolerance (`Test-ManagedDiskCapacityWithinTolerance`) rather
   than an exact byte match or an arbitrary broad tolerance -- this is a
   conservative application-level policy calibrated against the specific,
   real byte-count observations supplied for the three approved disks on
   these two VMs (see "Managed-disk capacity tolerance" below for the exact
   figures and calibration arithmetic), not a Microsoft-documented tolerance
   value or a claim about the root cause of why guest-reported capacity
   differs slightly from the nominal size. Size remains corroborating
   evidence only; it is never the sole identifier -- the reviewed, exact
   managed-disk resource ID and Azure LUN (and, where configured, the
   attested guest UniqueId in point 2a below) are what establish the
   selected target.

2a) Customer-attested guest-disk-UniqueId binding -- ENABLED for both real
   targets (see `Test-AttestedGuestUniqueIdBindingConfiguration`,
   `Select-NonOsNonTemporaryDiskCandidates`'s `-SkipTemporaryDiskExclusion`,
   and `Resolve-ApprovedDiskTarget`'s `-AttestedGuestUniqueId`). Every disk
   descriptor in the fixed allowlist carries an AttestedGuestUniqueId field.
   For App's one disk and both of Sql's disks, this field is now populated
   with the exact Get-Disk.UniqueId reviewed and recorded from customer-
   supplied guest diagnostics (see "`Get-ApprovedDiskPreparationAllowlist` —
   AttestedGuestUniqueId design and BINDING PROVENANCE" below for the exact
   evidence) -- completely and uniquely for each target, so both targets now
   disambiguate each approved LUN by its attested UniqueId instead of
   needing to positively exclude the (currently unreliable on these two VMs)
   temporary disk by size first. This correctly resolves the real LUN-number
   collision between the temporary disk (one SCSI controller) and SQL LOG
   (another), confirmed present in these VMs' own guest topology. This is
   ADDITIONAL verification only: the exact managed-disk resource ID
   (compared in full, never by prefix+suffix), Azure LUN, capacity, and
   state checks in point 2 above still ALL apply unchanged -- a UniqueId is
   never, by itself, treated as cryptographic or platform-asserted proof of
   the Azure resource relationship; Azure does not expose any mechanism this
   script can observe that attests it. A mixed (some but not all disks
   attested) or duplicate (the same attested UniqueId reused across more
   than one disk) configuration is a hard configuration error that blocks
   the whole target's plan, never a silent fallback -- and a disk that no
   longer resolves against its attested UniqueId (for example, after a disk
   replacement/recreation) blocks exactly the same way; nothing in this
   script discovers, refreshes, or re-derives a new UniqueId automatically
   -- that requires a new, separately reviewed binding. Populating these
   bindings changes only disk IDENTIFICATION; it does not itself enable or
   authorize any mutation -- every mutating action remains gated by `-Mode
   Apply` plus the module's own independent
   `enableGuestDiskPreparation`/`guestDiskPreparationExecutionTarget`
   opt-ins (both still committed as disabled/`'None'` -- see
   `docs/operations.md`).

3) Guest disk and partition state is fully validated, never auto-corrected.
   Disk-level IsOffline/IsReadOnly/OperationalStatus
   (https://learn.microsoft.com/en-us/powershell/module/storage/get-disk)
   are collected for every candidate disk; an offline, read-only, or
   non-"Online" approved disk blocks the entire VM's plan (for example, an
   unsuitable SQL LOG disk state blocks the DVD-ROM move AND every SQL DATA
   mutation, exactly like any other SQL LOG validation failure) -- this
   script never brings a disk online, clears its read-only flag, or
   otherwise mutates these states itself. Partition mount paths are
   validated against the full, documented set of legitimate access paths
   for a formatted basic data partition: the approved drive-letter root and
   that partition's own volume GUID path
   (https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-volume),
   correlated to the correct volume via Get-Volume's own `Path` property
   (which is exactly that GUID-path string) rather than by drive letter
   alone; any additional directory mount, any foreign volume's GUID path,
   any conflicting letter between a partition and its correlated volume, or
   any ambiguous correlation is a hard failure. The partition type is
   checked against the exact GPT Basic Data Partition type GUID
   (`ebd0a0a2-b9e5-4433-87c0-68b6b72699c7`, "This is the data partition type
   that is created and recognized by Windows" --
   https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-partition)
   rather than Get-Partition's friendly `Type` string ('Basic'/'IFS'), which
   is not itself an exact GPT-type guarantee.

4) Stable identity capture and re-validation, at every granularity. Every
   resolved disk's Windows Storage module UniqueId
   (https://learn.microsoft.com/en-us/powershell/module/storage/get-disk) is
   captured at first resolution. `-Mode Apply` unconditionally rebuilds the
   ENTIRE plan above from scratch -- fresh IMDS query, fresh guest
   disk/partition/volume/DVD/optical-device inventory, fresh
   allowlist/identity/LUN/mapping/state/partition/destination checks --
   immediately before any mutation (the whole-VM preflight), and confirms
   every disk's UniqueId has not changed between the two plans. In addition,
   immediately before EACH individual mutating call (the DVD-ROM move, and
   separately Initialize-Disk, New-Partition, and Format-Volume for every
   disk), this script independently re-resolves the exact same approved
   disk/device fresh one more time and asserts its identity and exact
   expected shape for that specific step -- see
   `Assert-DiskReadyForDestructiveStage` and `Assert-DvdReadyForMove`.
   Expected, in-progress state changes CAUSED BY THIS SAME INVOCATION'S own
   prior steps (for example, a disk now correctly showing GPT with only the
   Windows-generated MSR partition immediately after this invocation's own
   Initialize-Disk call) are recognized as the correct transition and
   allowed to proceed; any OTHER, unexplained change -- including ambiguous
   partial completion already present when the invocation started -- is
   always a hard failure. A previous (or even this same invocation's first)
   report is never treated as authorization to trust stale state, nothing is
   ever retried automatically, and no cleanup/rollback that deletes a
   partition is ever performed -- a destructive step that already succeeded
   earlier in this same invocation is never undone merely because a LATER
   step failed.

5) Complete, non-mutating preflight before any mutation on either target
   disk of a VM. Every approved disk's layout, partitions, volumes, mount
   paths (partition AccessPaths, not only drive letters), disk state, and
   drive-letter conflicts (against the WHOLE guest, not only approved disks)
   are validated up front. If any approved disk on a VM fails validation,
   the entire VM's plan is Blocked and ZERO mutations are attempted against
   ANY disk on that VM -- for example, a SQL LOG validation failure leaves
   SQL DATA completely untouched, even if SQL DATA's own checks would
   otherwise have passed. Guest inventory (disks, partitions, volumes, DVD
   volumes, optical devices) is fetched IN FULL exactly once per plan build,
   then filtered entirely in memory. This deliberately avoids per-letter/
   per-disk filtered guest queries with `-ErrorAction SilentlyContinue`,
   which would make a genuine query failure indistinguishable from a
   legitimate "no partitions"/"free letter" result -- a real query failure
   on the initial full fetch propagates as a hard failure instead.

6) RAW alone is never sufficient to initialize a disk -- it is treated only
   as one of several required preconditions (also: unambiguous LUN/name/
   size/UniqueId resolution, zero existing partitions, suitable disk state,
   and not boot/system), never as proof a disk has never held data. A disk
   already carrying the exact intended GPT layout (single data partition of
   the exact Basic Data type/size/mount-path set, NTFS, matching allocation
   unit size, label, and drive letter) is validated and left completely
   untouched, including when it already holds files -- this makes the
   script safe to run on every redeployment/revalidation. Windows may create
   a Microsoft Reserved (MSR) partition automatically as part of GPT
   initialization (every GPT disk must carry one -- see
   https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-and-gpt-faq)
   -- this one documented partition type is tolerated; any other unexpected
   partition, partition type, undersized/oversized layout, or partial
   completion (GPT-initialized but no/incomplete data partition) is a hard
   failure, never auto-repaired, auto-reformatted, or retried. Clear-Disk,
   diskpart clean, partition deletion, storage pools, and any blanket/
   wildcard disk-state change are never used anywhere in this script. Every
   mutating adapter targets an explicit disk, partition, or volume
   object/number -- never a drive letter alone. Unnecessary -Force flags are
   not used; Format-Volume suppresses only the interactive confirmation
   prompt (-Confirm:$false), which is required for unattended Run Command
   execution and is not itself a destructive-bypass flag.

7) SQL-only, conditional DVD-ROM letter move (E: -> the fixed allowlist's
   DvdLetterMoveTarget, 'Z'), positively verified via a dedicated, read-only
   Win32_CDROMDrive adapter
   (https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-cdromdrive).
   An empty Win32_Volume label alone does NOT establish that no media is
   loaded or that the device at E: is the approved virtual DVD-ROM -- the
   move is attempted only when exactly one optical device and exactly one
   CD-ROM-type volume are unambiguously correlated at E:, the device reports
   the exact expected device name (an OBSERVED property of these specific
   VMs, documented in the fixed allowlist as such, not a Microsoft-
   documented contract) and MediaLoaded=$false (the documented, positive "is
   media absent" signal -- an unknown/null MediaLoaded value blocks, it is
   never treated as "false"), and the target letter is confirmed free
   against the optical-device, DVD-volume, AND ordinary-volume/partition
   inventories. When the approved SQL DATA disk at E: is already
   independently and exactly correctly prepared (a second, idempotent run),
   the DVD-ROM is never inspected or touched at all -- "E: is not currently
   a DVD-ROM" is not itself a failure in that case. When a move is required,
   it is performed BEFORE the SQL DATA disk's own partition is created at E:,
   is re-verified immediately before the mutating call
   (`Assert-DvdReadyForMove`, re-checking the same device identity, media
   state, and source/destination occupancy one more time), and its success
   is independently re-confirmed afterward (the same device is now at the
   target letter, by its own Drive property, and E: is free) before any
   further mutation. The APP VM's DvdLetterMoveTarget is always empty, so
   its DVD-ROM letter is never evaluated for a move and never touched.

8) This script never touches pagefile configuration, the Azure temporary
   disk itself, SQL TempDB/configuration/folders/permissions/shares, or
   application content.

TESTABILITY. Decision/planning logic (`Get-ApprovedDiskPreparationAllowlist`,
`Test-TargetIdentityMatchesAllowlist`, `Select-NonOsNonTemporaryDiskCandidates`,
`Resolve-ApprovedDiskTarget`, `Get-DiskPreparationPlan`, `Get-DvdPreparationPlan`,
`Test-DestinationLetterOccupied`, `Get-GuestDiskPreparationPlan`,
`Test-DiskReadyForInitializeStage`, `Test-DiskReadyForNewPartitionStage`,
`Test-PartitionReadyForFormatStage`) operates exclusively on plain data
objects (hashtables/pscustomobjects) and never calls a real cmdlet -- it runs
identically, and is fully unit-testable, on any OS with any PowerShell
version, including Pester on Ubuntu CI with no Windows Storage cmdlets,
Windows CIM schemas, or administrator APIs available. All interaction with
real cmdlets is isolated in small, separately named "*Adapter" functions
(inventory adapters such as `Get-GuestDiskInventoryAdapter`; mutation
adapters such as `Initialize-ApprovedDiskAdapter`). Pester tests mock only
these adapters -- never the decision/planning functions themselves -- so the
actual safety logic always runs for real in every test. See
`Initialize-LimsGuestDataDisks.Tests.ps1`.

EXECUTION RUNTIME. Managed Run Command on Windows executes scripts under
Windows PowerShell 5.1 by default (scriptShell: 'Default' -- see
https://learn.microsoft.com/en-us/azure/templates/microsoft.compute/virtualmachines/runcommands
and https://devblogs.microsoft.com/azure-vm-runtime/using-powershell7-with-managed-runcommand/,
"all scripts run through Managed RunCommand will by default use Powershell
5"). This script deliberately targets Windows PowerShell 5.1 syntax and does
not request scriptShell: 'Powershell7' or install PowerShell 7 on either VM
merely to use newer syntax (e.g. -NoProxy on Invoke-RestMethod, which
requires PowerShell 6+). Requires administrator or SYSTEM execution; Run
Command executes as SYSTEM by default when no RunAsUser is supplied
(https://learn.microsoft.com/en-us/azure/virtual-machines/windows/run-command,
"Scripts run as System on Windows"), and this script independently verifies
that execution context rather than relying solely on that default.

## `Assert-GuestDiskPreparationFailure`

Raises a terminating error for this script's own control flow. Never calls
exit/Environment.Exit directly, so this function remains safe to invoke from
a dot-sourced, mocked Pester test -- only the top-level invocation guard at
the bottom of this file translates a thrown failure into a process exit code.

## `Get-ImdsResourceDiskSizeBytes` — IMDS `resourceDisk.size` discrepancy

Extracts IMDS's own authoritative report of this VM's temporary (resource)
disk size, in bytes, from a compute metadata object -- or $null if IMDS did
not report it at all (as opposed to reporting it as exactly zero, which is
IMDS's own documented value for "no local temp disk for this VM size"). See
https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service,
"Storage Profile" ("resourceDisk.size -- Size of the local temp disk for the
VM (in kB)" and "If there's no local temp disk for the VM, this value is
0.").

OBSERVED, CURRENTLY UNRESOLVED DISCREPANCY (do not "fix" the x1024
conversion in the script by guessing a different unit -- IMDS documents only
kB, and that documented unit is retained exactly as written in the script).
On the two real LIMS WS2025 DEV v2 VMs (Standard_D4ads_v5), IMDS was
observed to report `resourceDisk.size="201728"` while the VM's actual,
guest-observed temporary disk is 161059207680 bytes (~150 GiB -- consistent
with, though not independently re-verified against, the published
Standard_D4ads_v5 temp-disk size at
https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/general-purpose/dadsv5-series).
201728 kB x 1024 = 206,569,472 bytes (~197 MiB), which was not found to
reconcile with 161,059,207,680 bytes under this, or any other, single-unit
reinterpretation independently checked (kB/MB/sectors). This is reported
here only as an observation on these two specific VMs at the time they were
inspected -- it is NOT asserted to be a permanent condition, a proven Azure
platform defect, or a characteristic of this VM size/generation in general;
no authoritative Microsoft source establishing any of those broader claims
has been found, and none is cited here. Regardless of root cause, callers
must treat a resulting byte count that cannot be reconciled against any
guest disk as a hard blocking condition (see
`Select-NonOsNonTemporaryDiskCandidates`), never as "no temporary disk to
exclude" -- and the customer-attested guest-disk-UniqueId binding (see
`Get-ApprovedDiskPreparationAllowlist`), now populated for both real
targets, is the reviewed path that identifies disks on these two VMs
without depending on this discrepancy ever being resolved.

## Managed-disk capacity tolerance (`$script:ManagedDiskCapacityToleranceFraction`)

Real evidence from the two named v2 VMs shows the guest's own reported
`Get-Disk.Size` for a managed data disk can legitimately be a small amount
SMALLER than the nominal diskSizeGB-derived byte count: observed ~19.67 ppm
(0.00197%) for the APP data disk (137436250112 vs nominal 137438953472
bytes) and ~5.05 ppm (0.000505%) for each SQL disk (1099506078720 vs nominal
1099511627776; 549753039360 vs nominal 549755813888). IMDS does not expose a
separate, authoritative platform capacity field for these specific (non-
Ultra) managed disks to corroborate this independently (diskCapacityBytes
was observed empty/absent, diskSizeGB is the only populated IMDS capacity
value for them --
https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service),
so no Microsoft-documented value or formula explaining WHY the guest-
reported byte count differs from the nominal size is cited or relied on
here; the existence of separate DiskSizeGB/DiskSizeBytes properties on the
Azure Disk resource, and Azure's documented billing-tier rounding behavior,
are NOT used as proof of this discrepancy's cause -- they would describe a
different value (the platform's own internal record of the disk) than what
is actually being compared here (the guest's own Get-Disk.Size report). The
tolerance is instead a deliberately conservative, FIXED, application-level
policy, calibrated directly against the specific real byte-count
observations above (with a >2x margin above the worst of them, 19.67 ppm),
and applied ONE-SIDED -- rejecting any guest-reported capacity GREATER than
nominal, on the conservative assumption that a managed disk should never
appear larger to the guest than what was provisioned, while tolerating the
small observed shortfall. It is not a Microsoft-published tolerance value.
Size remains corroborating evidence only, never the sole identifier -- the
exact managed-disk resource ID, Azure LUN, and (where configured) customer-
attested UniqueId checks elsewhere are what establish the selected target.

`Test-ManagedDiskCapacityWithinTolerance` is true when ActualBytes is at
most NominalBytes, and no more than
`$script:ManagedDiskCapacityToleranceFraction` smaller than NominalBytes.

## `Get-ApprovedDiskPreparationAllowlist` — AttestedGuestUniqueId design and BINDING PROVENANCE

Independent, fixed, hardcoded allowlist -- the single source of truth for
exactly which subscription/resource-group/VM/computer/disk/LUN/size/drive-
letter/label/allocation-unit combination may ever be touched. See the module
`.DESCRIPTION` above: caller parameters and IMDS must EACH independently
match this allowlist.

`ExpectedOpticalDriveName` is an OBSERVED property (Win32_CDROMDrive's
documented `Name` field --
https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-cdromdrive)
of these two specific Azure VMs' virtual DVD-ROM device, not a Microsoft-
documented guarantee for all Azure VMs; it is only ever used by Sql to
positively verify the device at E: before moving it, never to identify a
disk.

`AttestedGuestUniqueId` activates the customer-attested guest-disk-UniqueId
binding mechanism described in `docs/operations.md` ("Customer-attested
guest-disk-UniqueId binding"). When every disk for a given target carries a
non-empty, mutually unique value here, that target switches to an alternate
guest-disk-identification mode (`Test-AttestedGuestUniqueIdBindingConfiguration`,
`Select-NonOsNonTemporaryDiskCandidates -SkipTemporaryDiskExclusion`,
`Resolve-ApprovedDiskTarget -AttestedGuestUniqueId`) that disambiguates each
approved LUN by its attested UniqueId instead of by excluding the (currently
unreliable -- see "`Get-ImdsResourceDiskSizeBytes` — IMDS resourceDisk.size
discrepancy" above) temporary disk by size. This is ADDITIONAL verification
layered on top of, never a REPLACEMENT for, the exact managed-disk-resource-
ID/LUN checks, which still apply unchanged -- and it is never, by itself,
treated as cryptographic or platform-asserted proof that a given Azure
managed-disk resource and a given guest `Get-Disk.UniqueId` are the same
disk. Azure does not cryptographically attest this relationship anywhere
this script can observe; this value is a customer-supplied diagnostic
observation (see "Binding provenance" immediately below for the exact
evidence and how/when it was captured), reviewed and committed here as a
deliberate, reviewed decision -- never derived automatically, never
refreshed automatically, and never silently re-validated against live guest
state by this allowlist itself (`Resolve-ApprovedDiskTarget` still
independently re-confirms the managed-disk resource ID, LUN, capacity, and
guest disk state every time it runs; only the UniqueId-based disambiguation
step itself trusts this value). A disk's AttestedGuestUniqueId left '' keeps
that target on the default, fully-automatic identification path.

BINDING PROVENANCE (for the three disks populated in the allowlist). Captured
from customer-supplied, read-only Azure/guest inventory evidence for the two
real LIMS WS2025 DEV v2 VMs (subscription
8ebb26a1-674a-40d1-97f8-e0a237e288a6, resource group
rg-compute-lims-dev-westeu), reviewed and recorded as of the commit that
introduced them -- not independently re-queried or re-verified by this
script at any point, and not a guarantee that these values remain correct
after any future disk replacement/recreation on either VM (see
`Test-AttestedGuestUniqueIdBindingConfiguration`'s own comment and
`docs/operations.md` for what happens if a UniqueId changes: the bound disk
fails to resolve and the whole target's plan blocks -- it is never treated
as "no longer attested" and silently routed back to the automatic path).

Per-disk provenance detail:

- **APP disk (LUN 0, `appdata-vm-lims-dev-v2-westeu-001`)**: observed
  `Get-Disk.UniqueId` on `vm-lims-dev-v2-westeu-001`'s LUN-0 disk; actual
  guest capacity observed as 137436250112 bytes against the 128 GiB nominal
  size -- within `Test-ManagedDiskCapacityWithinTolerance`.
- **SQL DATA disk (LUN 0, `sqldata-vm-lims-dev-v2-westeu-002`)**: observed
  `Get-Disk.UniqueId` on `vm-lims-dev-v2-westeu-002`'s LUN-0 disk; actual
  guest capacity observed as 1099506078720 bytes against the 1024 GiB
  nominal size.
- **SQL LOG disk (LUN 1, `sqllog-vm-lims-dev-v2-westeu-002`)**: observed
  `Get-Disk.UniqueId` on `vm-lims-dev-v2-westeu-002`'s LUN-1 disk; actual
  guest capacity observed as 549753039360 bytes against the 512 GiB nominal
  size. This disk's guest SCSILogicalUnit is also the one that numerically
  collides with the VM's own temporary disk (see "`Get-ImdsResourceDiskSizeBytes`
  — IMDS resourceDisk.size discrepancy" above) -- this attested UniqueId is
  exactly what disambiguates the two in `Resolve-ApprovedDiskTarget`.

## `Test-AttestedGuestUniqueIdBindingConfiguration`

Pure validation of the customer-attested guest-disk-UniqueId binding
mechanism (see "`Get-ApprovedDiskPreparationAllowlist` — AttestedGuestUniqueId
design and BINDING PROVENANCE" above and `docs/operations.md`). This binding
is ADDITIONAL verification only, layered on top of (never a replacement for)
the exact managed-disk-resource-ID + Azure LUN checks already performed in
`Resolve-ApprovedDiskTarget` -- a UniqueId is never, by itself, treated as
cryptographic or platform-asserted proof of the Azure resource relationship.

Returns `IsAttestedMode=$true` only when EVERY disk for this target carries
a non-empty, and mutually unique, AttestedGuestUniqueId (an explicit,
deliberate, all-or-nothing-per-VM opt-in) -- the actual state for both real
App and Sql allowlist entries as of the commit that populated the bindings
(see "BINDING PROVENANCE" above). Returns `IsAttestedMode=$false` with no
error when NONE do -- the state for any target whose AttestedGuestUniqueId
fields are left at their default ''. Any OTHER configuration -- some but not
all disks attested (a "missing" binding), or the same attested UniqueId
reused across more than one disk for the same target (a "duplicate"
binding) -- is a hard configuration error that blocks the whole target's
plan rather than silently choosing a mode or falling back.

## `Select-NonOsNonTemporaryDiskCandidates`

Excludes the OS disk (Get-Disk's own documented IsBoot/IsSystem flags --
https://learn.microsoft.com/en-us/powershell/module/storage/get-disk) and
the Azure temporary/resource disk from the candidate pool later used to
resolve approved data-disk targets by LUN.

The temporary/resource disk is NOT a managed disk
(https://learn.microsoft.com/en-us/azure/virtual-machines/managed-disks-overview,
"Temporary disk" -- "Most VMs contain a temporary disk, which isn't a
managed disk") and therefore never appears in IMDS's
`storageProfile.dataDisks[]` by LUN; it is positively identified here by
cross-referencing TWO independent, Microsoft-documented sources -- the Azure
platform's own authoritative report of this VM's temporary disk size (IMDS
`compute.storageProfile.resourceDisk.size` --
https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service)
against each remaining candidate disk's own guest-reported size
(`Get-Disk.Size`). This is never a guess from guest-only topology, a drive
letter, a label, or a disk number -- and it is never used as the SOLE basis
for excluding a disk: a disk is only ever excluded here when its size
matches Azure's own independently reported temporary-disk size, and any
ambiguity (more than one candidate matching) is a hard failure, never a
silent pick. A previous version of this function instead assumed every
non-OS disk sharing the OS disk's SCSI bus/port was temporary storage,
citing an unofficial, third-party source -- that assumption has been
removed; no guest-side SCSI/controller co-location heuristic, and no
hardcoded port number, is used anywhere in this function now.

If IMDS does not report resourceDisk.size at all (missing, not merely
zero), this is treated as "supported interfaces cannot establish sufficient
identity" and the whole plan fails closed rather than silently skipping the
exclusion -- see `docs/operations.md` for what read-only diagnostic evidence
to collect if this occurs on a real VM, and `Get-LimsGuestDiskDiagnostics.ps1`
alongside this script for a ready-made, read-only tool to collect it.

Separately, ANY non-OS disk reporting missing/invalid SCSI addressing (this
script's own -1 sentinel for "Win32_DiskDrive lookup failed") is never
allowed to become a data-disk candidate -- it cannot be correlated to an
Azure LUN at all, so admitting it would risk an unverifiable mapping.

DEFECT FIX (previously accepted a "zero matches" result as "no temporary
disk present"): when IMDS reports a NONZERO resourceDisk.size (i.e., the
platform itself asserts this VM has a temporary disk), failing to find
EXACTLY ONE non-OS disk whose reported size matches it is now ALSO a hard
failure -- a nonzero platform claim that cannot be positively,
unambiguously resolved against any guest disk must never be silently
treated as "nothing to exclude," since that would risk admitting the real,
unexcluded temporary disk as a data-disk candidate. On the two real LIMS
WS2025 DEV v2 VMs, this has been observed to correctly block this
identification path (see "`Get-ImdsResourceDiskSizeBytes` — IMDS
resourceDisk.size discrepancy" above for the observed, currently unresolved
discrepancy driving this, which is not asserted to be permanent) -- see
`Test-AttestedGuestUniqueIdBindingConfiguration`/`-SkipTemporaryDiskExclusion`,
now enabled for both real targets via their populated AttestedGuestUniqueId
bindings, for the alternate identification path that does not depend on
this discrepancy being resolved.

The `-ImdsResourceDiskSizeBytes` parameter deliberately allows `$null` (not
typed `[int64]`) so "IMDS did not report it at all" flows through as `$null`
rather than crashing on parameter binding. The `-SkipTemporaryDiskExclusion`
parameter activates the customer-attested guest-disk-UniqueId binding
mechanism (see `Test-AttestedGuestUniqueIdBindingConfiguration` and
`Resolve-ApprovedDiskTarget`'s own `-AttestedGuestUniqueId` parameter). When
`$true`, temporary-disk exclusion by size is skipped entirely here -- NOT
because identity verification is weakened, but because every approved disk
is instead positively disambiguated by its own attested UniqueId later in
`Resolve-ApprovedDiskTarget`, which makes excluding the temporary disk here
unnecessary (it simply will never match any approved LUN+UniqueId pair).
Always `$false` unless the caller has already confirmed (via
`Test-AttestedGuestUniqueIdBindingConfiguration`) that every disk for this
target carries a valid attested binding.

## `Resolve-ApprovedDiskTarget`

Resolves exactly one approved disk descriptor to a Windows disk, after
independently validating: an unambiguous IMDS LUN match, managed-disk
resource name/ID, capacity, an unambiguous match among the (already
OS/temporary-excluded) candidate guest disks, non-boot/non-system flags,
suitable operational state (online, not read-only, OperationalStatus
'Online'), and a captured stable UniqueId. Returns a pscustomobject with
either `.Target` (resolved, carrying the disk state fields forward for
reporting) or `.Error` (a reason string) set -- never throws, so callers can
continue collecting every error for the whole VM before deciding anything is
Blocked.

`-AttestedGuestUniqueId` (optional, '' by default) activates the customer-
attested guest-disk-UniqueId binding mechanism for THIS disk (see
"`Get-ApprovedDiskPreparationAllowlist` — AttestedGuestUniqueId design and
BINDING PROVENANCE" above and `Test-AttestedGuestUniqueIdBindingConfiguration`).
When non-empty, the guest disk at the approved LUN must ALSO carry this
exact UniqueId -- disambiguating cleanly even when a LUN number numerically
collides between the real target disk and an unrelated disk (e.g. the
temporary disk on a different SCSI controller reusing the same raw LUN
number). This is ADDITIONAL verification layered on top of (never a
replacement for) every other check -- the managed-disk resource ID, LUN,
capacity, state, and UniqueId-non-empty checks all still apply unchanged; a
UniqueId is never, by itself, treated as proof of the Azure resource
relationship.

The managed-disk resource ID check is deliberately an exact, full-string
equality against one fully-constructed expected resource ID -- NOT
`StartsWith(prefix) + EndsWith(diskName)` (a prior version used that
combination, which could wrongly accept an ID with an intervening,
unexpected path segment between the resource-group/provider prefix and the
trailing disk-name segment, e.g.
`.../disks/unexpected-segment/appdata-vm-lims-dev-v2-westeu-001` -- that
string starts with the expected prefix and ends with the expected disk
name, yet is not the real disk's resource ID). Building the one exact,
fully-qualified expected ID and comparing it in full closes that gap.

## `Get-DiskPreparationPlan`

Decides exactly one of: Initialize (RAW, zero partitions, suitable state --
every identity/mapping check already passed in `Resolve-ApprovedDiskTarget`),
NoOp (GPT, already matching the intended layout exactly, including the exact
Basic Data partition type/capacity/mount-path set -- left untouched even if
it already holds files), or Fail (anything else: unexpected partition
count/type/size/mount-path, foreign or missing volume-GUID correlation,
conflicting drive letters, partial completion, mismatched NTFS layout, or an
unexpected PartitionStyle). Never mutates anything.

Mount-path shape: only the approved drive-letter root and, once formatted,
exactly one volume-GUID access path
(https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-volume) are
ever accepted -- never an additional directory mount, and never more than
one GUID path (which would itself be ambiguous). The partition's own
volume-GUID access path must be exactly the correlated volume's own Path
(Get-Volume's Path property is exactly the same GUID-path string -- this is
what proves the correlation is this partition's OWN verified volume, never
a foreign volume's GUID path, and never simply absent once formatted).

## `Get-DvdPreparationPlan`

SQL-only DVD-ROM letter-move decision: Move, AlreadyCorrect/NoneRequired
(nothing to do), or Fail. Never mutates anything. See the module
`.DESCRIPTION`, point 7, for the full decision rules.

Positive verification before ever planning a Move: an empty Win32_Volume
label alone does NOT establish that no media is loaded or that the device
at E: is the approved virtual DVD-ROM (that was this function's previous,
weaker behavior). This version requires an unambiguous, positively
identified Win32_CDROMDrive device at E:
(https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-cdromdrive)
reporting the exact expected device Name and MediaLoaded=$false (an
unknown/null MediaLoaded value is never treated as "false"), correlated 1:1
with exactly one CD-ROM-type Win32_Volume at E:.

If the approved E: target already matches its intended layout exactly
(NoOp), E: already belongs to the correctly prepared SQL DATA volume --
never attempt a DVD move, and never fail merely because E: is not a DVD-ROM
in that case. E: is never even inspected for DVD-ness here.

## `Test-DestinationLetterOccupied`

Checks whether a candidate destination letter (e.g. the DVD-ROM move target
'Z') is already occupied, across EVERY relevant inventory -- the optical-
device inventory (its own Drive property), the DVD-volume inventory, the
ordinary volume inventory, and the partition inventory -- so that neither
"some other DVD is already there" nor "some unrelated ordinary
volume/partition is already there" can be missed by checking only one
source.

## `Test-DiskReadyForInitializeStage` / `Test-DiskReadyForNewPartitionStage` / `Test-PartitionReadyForFormatStage`

These three functions are pure shape assertions for the IMMEDIATE
pre-mutation rechecks performed by `Assert-DiskReadyForDestructiveStage`
immediately before each of Initialize-Disk, New-Partition, and
Format-Volume respectively. Each returns `$null` when ready, or a reason
string when not -- never throws itself.

- **Pre-Initialize-Disk**: the freshly re-resolved disk must still be RAW,
  zero partitions, suitable state, and the approved drive letter must still
  be free guest-wide.
- **Pre-New-Partition**: the disk must now show exactly the expected
  post-initialization state (GPT, suitable state, only the Windows-
  generated MSR partition, no data partition yet) -- this EXPECTED,
  in-progress state change (RAW -> GPT+MSR) caused by this same
  invocation's own prior Initialize-Disk call is recognized as correct and
  allowed to proceed; any OTHER partition already present is always
  unexpected.
- **Pre-Format-Volume**: the same disk identity must now show exactly the
  newly created data partition -- same partition number as the one just
  created, exact Basic Data GPT type, matching size, and the approved drive
  letter -- with no filesystem already present.

## `Get-GuestDiskPreparationPlan`

Builds one complete, read-only plan: allowlist/identity verification
(caller params AND IMDS, each independently), OS/temporary disk exclusion,
per-approved-disk resolution + preparation plan, a whole-guest drive-letter
conflict preflight, and (SQL only) the DVD-ROM letter-move plan. Never calls
a mutating adapter. Used identically for `-Mode Validate` and as the
mandatory, fresh, immediately-pre-mutation re-validation inside `-Mode
Apply`.

The per-disk loop variable inside this function is deliberately named
`$resolvedEntry`, never `$target` -- PowerShell variables are
case-insensitive, so a loop variable named `$target` would be the SAME
variable slot as this function's own typed `[string] $Target` parameter.
Assigning a pscustomobject to that slot would silently coerce it to a
string (via `.ToString()`) instead of erroring, which would then make every
`$resolvedEntry.Target.DiskNumber`/`.DriveLetter`/etc. access fail with a
confusing `PropertyNotFoundException`. This was caught by actually running
these tests under Windows PowerShell 5.1 locally, not by static review.

The per-disk AttestedGuestUniqueId used for resolution is looked up from the
fixed ALLOWLIST's own Disks (never from caller-supplied `$ExpectedDisks`,
which carries no AttestedGuestUniqueId field at all by design) -- the
attested binding is a deliberate, hardcoded, reviewed code-level opt-in,
never something a caller/Bicep parameter can supply or influence.

## `Get-ImdsComputeMetadataAdapter`

Windows PowerShell 5.1 compatible IMDS query. `-NoProxy` on
`Invoke-RestMethod` requires PowerShell 6+ and is unavailable in Windows
PowerShell 5.1 -- the runtime Run Command actually uses on Windows by
default. This uses the documented PowerShell 5-compatible proxy-bypass
technique instead (an empty `System.Net.WebProxy` bound to a
`WebRequestSession`), taken from Microsoft's own IMDS sample repository and
troubleshooting guidance:
https://github.com/Microsoft/azureimds/blob/master/IMDSSample.ps1
https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/activation-watermark-appears
("PowerShell 5 and earlier versions"). The api-version used (2025-04-07) is
well after resourceDisk.size became available (documented from api-version
2021-02-01 --
https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service),
so it is included automatically as part of the full compute object.

## `Get-GuestDiskInventoryAdapter`

Merges Get-Disk (Windows Storage module: IsBoot/IsSystem/IsOffline/
IsReadOnly/OperationalStatus/PartitionStyle/Size/UniqueId --
https://learn.microsoft.com/en-us/powershell/module/storage/get-disk) with
Win32_DiskDrive (SCSI addressing: SCSIBus/SCSIPort/SCSITargetId/
SCSILogicalUnit --
https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-diskdrive)
into one plain-object inventory, fetched in full exactly once.

## `Get-GuestVolumeInventoryAdapter`

Get-Volume's own `Path` property is exactly the volume's own canonical
volume-GUID path -- the documented identifier used (instead of drive letter
alone) to correlate a partition's AccessPaths to this specific volume. See
https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-volume.

## `Get-GuestDvdVolumeInventoryAdapter`

Win32_Volume (not Get-Volume) is used specifically because it is the only
documented way to later change an optical drive's letter (`Set-CimInstance
-InputObject`); fetched once, in full, for the same reason as the other
inventory adapters.

## `Get-GuestOpticalDriveInventoryAdapter`

Win32_CDROMDrive -- the documented source for an optical device's own
stable identity (DeviceID, which "does not correspond to the logical drive
letter" and so survives a drive-letter move) and positive media-loaded
state (MediaLoaded). See
https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-cdromdrive.
MediaLoaded is deliberately left as whatever WMI reports (which can be
`$null`, i.e. unknown) rather than force-cast to `[bool]`, since
`Get-DvdPreparationPlan` must be able to tell "unknown" apart from "false".

## `Get-FreshGuestDiskPreparationPlan`

Gathers every adapter's inventory fresh (no caching, no reuse across calls)
and builds one complete plan via `Get-GuestDiskPreparationPlan`. Called at
least twice per `-Mode Apply` invocation -- see `Invoke-GuestDiskPreparation`
-- so that a previous plan is never treated as authorization to trust stale
state.

Every adapter call is wrapped in `@(...)` at the ASSIGNMENT site, not only
inside each adapter's own return statement. A real guest state with zero
partitions/volumes/DVD/optical devices (e.g. a freshly RAW disk, or no
optical drive attached at all) is entirely legitimate -- but PowerShell
unrolls a zero-element array returned from a function onto the output
stream as zero objects, so an unwrapped `$x = Get-SomeAdapter` assignment
would silently become `$null` rather than an empty array in exactly that
legitimate case, which would then fail Mandatory-but-AllowEmptyCollection
binding with a confusing "because it is null" error instead of flowing
through normally. This was caught by actually running these tests under
Windows PowerShell 5.1 locally, not by static review.

## `Assert-DiskReadyForDestructiveStage`

Immediately before Initialize-Disk / New-Partition / Format-Volume:
re-fetches a FRESH IMDS query and FRESH guest disk/partition/volume
inventory (never reusing the whole-VM `$applyPlan` snapshot built earlier in
this same invocation) and re-resolves exactly the one approved disk
descriptor for this disk plan, confirming its UniqueId/disk number have not
changed, then applies a stage-specific pure shape assertion
(`Test-DiskReadyForInitializeStage`/`Test-DiskReadyForNewPartitionStage`/
`Test-PartitionReadyForFormatStage`). Throws (via
`Assert-GuestDiskPreparationFailure`) on any mismatch -- never retries,
never rolls back a prior successful step in this same invocation.

`-Target` is used ONLY to look up the SAME fixed allowlist entry's own
AttestedGuestUniqueId configuration (never caller-supplied) so the
customer-attested-binding mechanism, if active for this VM, is honored
consistently in every immediate pre-mutation re-check -- never silently
falling back to the default/automatic identification path merely because
this is a later re-check rather than the first plan build. By the time this
function is ever called, the caller's own whole-VM preflight has already
confirmed this target's attested-binding configuration is valid (not mixed
or duplicate) -- this function trusts that, it does not re-validate it.

## `Assert-DvdReadyForMove`

Immediately before the mutating DVD-ROM letter move: re-fetches every
relevant inventory fresh (never reusing the whole-VM `$applyPlan` snapshot)
and re-runs the SAME positive-verification decision logic
(`Get-DvdPreparationPlan`), confirming the SAME optical device identity
(DeviceId), media state, and source/destination occupancy are still exactly
as previously verified. Returns the re-checked plan (so the caller uses
its, not the stale plan's, DeviceId) or throws on any mismatch.

`EDataDiskPlanAction` is deliberately passed as `'Initialize'` (a
placeholder meaning merely "not NoOp") -- the caller only reaches this
function after already confirming, via the whole-VM `$applyPlan`, that the
SQL DATA disk is NOT already correctly prepared; recomputing that here
would require re-running the entire disk plan rather than just this
device's own identity/media/occupancy state.

## GPT partition-type and volume-GUID-path constants

- `$script:MsrPartitionGptType`: GPT partition-type GUID for a Microsoft
  Reserved (MSR) partition. Source:
  https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-and-gpt-faq
  ("Microsoft Reserved Partition (MSR)") and
  https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-partition
  (GptType "Microsoft Reserved e3c9e316-0b5c-4db8-817d-f92df00215ae"). This
  is the one, documented, Windows-generated partition type tolerated
  alongside the single intended data partition -- never treated as license
  to accept any other unexpected partition.
- `$script:BasicDataPartitionGptType`: GPT partition-type GUID for a Basic
  Data Partition -- "the data partition type that is created and recognized
  by Windows. Only partitions of this type can be assigned drive letters,
  receive volume GUID paths, host mounted folders ... and be enumerated by
  calls to FindFirstVolume and FindNextVolume." Source:
  https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-partition
  (MSFT_Partition.GptType). This is the EXACT type checked for the single
  approved data partition on each disk -- never Get-Partition's friendly
  `Type` string ('Basic'/'IFS'), which is not itself an exact GPT-type
  guarantee.
- `$script:VolumeGuidPathPattern`: a volume GUID path, as documented in
  "Naming a Volume"
  (https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-volume):
  `\\?\Volume{ GUID}` (with a trailing backslash, as returned by the volume
  and mounted-folder functions, and as reported in Get-Partition's own
  AccessPaths and Get-Volume's own Path property). Used to recognize this
  single, specific, documented access-path shape among a partition's
  AccessPaths, as distinct from a drive-letter root or any other mounted
  folder.
