#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
swift test --package-path Packages/NativeMusic --filter 'AudioEffectsTests|DecodedTransportTests|CodecBoundaryTests|QueueNativeHandoffTests|RetainedDSPTests|DSPReworkTests|QueueIntervalReworkTests|QueueAdoptionReworkTests|StagedResetReworkTests|HandoffPersistenceFaultTests'
