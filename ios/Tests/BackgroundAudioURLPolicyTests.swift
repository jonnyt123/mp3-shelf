import Foundation

/// Native target regression: compile with MP3Shelf's downloader and service
/// dependencies. No network requests are made.
@main
enum BackgroundAudioURLPolicyTests {
    static func main() {
        let rejected = [
            "http://audio.example/recording.mp3",
            "https://localhost/recording.mp3",
            "https://audio.example./recording.mp3",
            "https://open.spotify.com./track/fixture",
            "https://r1.googlevideo.com./videoplayback",
            "https://speaker.local/recording.mp3",
            "https://gateway.internal/recording.mp3",
            "https://127.0.0.1/recording.mp3",
            "https://192.168.1.2/recording.mp3",
            "https://[::1]/recording.mp3",
            "https://0x7f.0.0.1/recording.mp3",
            "https://0177.0.0.1/recording.mp3",
            "https://user:password@audio.example/recording.mp3",
            "https://audio.example:8443/recording.mp3",
            "https://audio.example/recording.mp3#fragment",
            "https://open.spotify.com/track/fixture",
            "https://r1.googlevideo.com/videoplayback"
        ]
        for raw in rejected {
            guard let url = URL(string: raw),
                  !BackgroundAudioDownloader.allowedDownloadURL(url) else {
                fatalError("Rejected background URL was accepted: \(raw)")
            }
        }
        let accepted = [
            "https://cdn.audio.example/recording.mp3",
            "https://media.example.org/files/recording.m4a?token=fixture"
        ]
        for raw in accepted {
            guard let url = URL(string: raw),
                  BackgroundAudioDownloader.allowedDownloadURL(url) else {
                fatalError("Safe public HTTPS URL was rejected: \(raw)")
            }
        }
        // A complete staged recording wins against late HTTP failures,
        // cancellation errors and progress-limit callbacks. A cancelled or
        // already imported ticket must not revive a stale staged file.
        for queued in [false, true] {
            for staged in [false, true] {
                for importing in [false, true] {
                    let expected = queued && (staged || importing)
                    guard BackgroundAudioDownloader.shouldDeferCallbackFailure(
                        isQueued: queued, hasStagedFile: staged,
                        isImporting: importing) == expected else {
                        fatalError("Incorrect callback precedence: queued=\(queued), staged=\(staged), importing=\(importing)")
                    }
                }
            }
        }
        // A relaunched downloader can recover a bounded approval, but no
        // session-level setting may override a request without consent.
        let fixtureURL = URL(string: "https://audio.example.org/song.mp3")!
        for approved in [false, true] {
            let request = BackgroundAudioDownloader.requestForAudio(
                fixtureURL, cellularApproved: approved)
            guard request.allowsCellularAccess == approved,
                  request.allowsExpensiveNetworkAccess == approved,
                  request.allowsConstrainedNetworkAccess == approved else {
                fatalError("Incorrect cellular request permissions for approval=\(approved)")
            }
        }
        // Opt-in must not cancel an active decoder or restart a recording
        // whose staged bytes are already ready for library import.
        for queued in [false, true] {
            for staged in [false, true] {
                for importing in [false, true] {
                    for cellular in [false, true] {
                        let expected = queued && !staged && !importing && !cellular
                        guard BackgroundAudioDownloader.mayUpgradeToCellular(
                            isQueued: queued, hasStagedFile: staged,
                            isImporting: importing,
                            taskAlreadyAllowsCellular: cellular) == expected else {
                            fatalError("Incorrect cellular upgrade eligibility")
                        }
                    }
                }
            }
        }
        // A shared task is safe only for the exact recording and URL,
        // while its leader remains queued in a different playlist.
        var validSharedCases = 0
        for sameRecording in [false, true] {
            for sameURL in [false, true] {
                for leaderQueued in [false, true] {
                    for samePlaylist in [false, true] {
                        let expected = sameRecording && sameURL && leaderQueued && !samePlaylist
                        guard BackgroundAudioDownloader.mayShareTransfer(
                            sameRecording: sameRecording, sameURL: sameURL,
                            leaderQueued: leaderQueued, samePlaylist: samePlaylist) == expected else {
                            fatalError("Shared download eligibility regression")
                        }
                        validSharedCases += 1
                    }
                }
            }
        }
        guard validSharedCases == 16 else { fatalError("Incomplete sharing matrix") }
        // Ten playlists following one leader must not exhaust the same
        // network concurrency slots as eleven physical transfers. Retry
        // capacity must use this same physical count as initial enqueue.
        for leaders in 0...4 {
            for searches in 0...4 {
                let physical = BackgroundAudioDownloader.physicalTransferCount(
                    queuedLeaderCount: leaders, sourceSearchCount: searches)
                guard physical == leaders + searches else {
                    fatalError("Shared follower incorrectly consumed network capacity")
                }
            }
        }
        guard BackgroundAudioDownloader.physicalTransferCount(
            queuedLeaderCount: -1, sourceSearchCount: -1) == 0 else {
            fatalError("Invalid capacity count must not become negative")
        }
        // Retrying another playlist's identical recording can attach to a
        // running leader even when the physical transfer budget is full.
        // Without either an existing leader or capacity, retry must defer.
        var retryCapacityCases = 0
        for leader in [false, true] {
            for freeSlot in [false, true] {
                guard BackgroundAudioDownloader.mayRetryWithSharedCapacity(
                    hasQueuedLeader: leader, hasFreeTransferSlot: freeSlot) ==
                    (leader || freeSlot) else {
                    fatalError("Shared retry capacity regression")
                }
                retryCapacityCases += 1
            }
        }
        guard retryCapacityCases == 4 else { fatalError("Incomplete shared retry capacity matrix") }
        print("PASS: 4 shared retry capacity combinations")
        print("PASS: 26 physical-transfer capacity combinations")
        var promotionCases = 0
        for loaded in [false, true] {
            for current in [false, true] {
                for stored in [false, true] {
                    let expected = loaded && current && !stored
                    guard BackgroundAudioDownloader.mayPromoteSharedFollower(
                        playlistLoaded: loaded, requestCurrent: current,
                        alreadyStored: stored) == expected else {
                        fatalError("Orphan follower promoted without a current playlist request")
                    }
                    promotionCases += 1
                }
            }
        }
        guard promotionCases == 8 else { fatalError("Incomplete follower promotion matrix") }
        // Cancelling a leader during an asynchronous decode must not launch
        // a second network transfer until that decoder has exited.
        var importRaceCases = 0
        for processing in [false, true] {
            for converting in [false, true] {
                let expected = !processing && !converting
                guard BackgroundAudioDownloader.mayPromoteAfterImport(
                    isProcessing: processing, hasConversion: converting) == expected else {
                    fatalError("Follower promoted while prior import still owns staged bytes")
                }
                importRaceCases += 1
            }
        }
        guard importRaceCases == 4 else { fatalError("Incomplete import race matrix") }
        print("PASS: 4 cancellation/import race promotion combinations")
        // On relaunch, a completed URLSession task may have left audio bytes
        // in staging even though its ticket was cancelled or retired. Do not
        // promote a follower until staging recovery has inspected those bytes.
        var stagedRecoveryCases = 0
        for staged in [false, true] {
            for processing in [false, true] {
                for converting in [false, true] {
                    let expected = !staged && !processing && !converting
                    guard BackgroundAudioDownloader.mayPromoteAfterStagingRecovery(
                        hasPredecessorStaging: staged,
                        isProcessing: processing,
                        hasConversion: converting) == expected else {
                        fatalError("Staged predecessor duplicate-transfer regression")
                    }
                    stagedRecoveryCases += 1
                }
            }
        }
        guard stagedRecoveryCases == 8 else { fatalError("Incomplete staging recovery matrix") }
        print("PASS: 8 staged predecessor promotion safety combinations")
        // Cancellation must not strand followers after removing an unused
        // staged file, and must not race a decoder or a failed cleanup.
        var cancellationCases = 0
        for processing in [false, true] {
            for converting in [false, true] {
                for stagedAfterCleanup in [false, true] {
                    let expected = !processing && !converting && !stagedAfterCleanup
                    guard BackgroundAudioDownloader.mayPromoteAfterCancellation(
                        isProcessing: processing,
                        hasConversion: converting,
                        hasStagedFile: stagedAfterCleanup) == expected else {
                        fatalError("Cancelled leader follower promotion regression")
                    }
                    cancellationCases += 1
                }
            }
        }
        guard cancellationCases == 8 else { fatalError("Incomplete cancellation cleanup matrix") }
        print("PASS: 8 cancellation cleanup and follower promotion combinations")


        print("PASS: 8 orphan follower promotion eligibility combinations")
        // A leader may retire while a sibling playlist is still loading.
        // Retargeting it is mandatory: dropping it would create a second
        // orphaned leader on the next process launch.
        for promoted in [false, true] {
            for obsolete in [false, true] {
                let expected = !promoted && !obsolete
                guard BackgroundAudioDownloader.shouldRetargetFollower(
                    isPromoted: promoted, isConfirmedObsolete: obsolete) == expected else {
                    fatalError("Shared follower retargeting regression")
                }
            }
        }
        print("PASS: 4 shared-follower promotion and orphan-retarget cases")
        // Exhausted shared sources must fail all attached requests together,
        // rather than promoting each follower to redownload known-bad bytes.
        var terminalCases = 0
        for queued in [false, true] {
            for matches in [false, true] {
                let expected = queued && matches
                guard BackgroundAudioDownloader.shouldFailSharedFollower(
                    isQueued: queued, leaderMatches: matches) == expected else {
                    fatalError("Shared source terminal failure fanout regression")
                }
                terminalCases += 1
            }
        }
        guard terminalCases == 4 else { fatalError("Incomplete shared failure matrix") }
        print("PASS: 4 shared source terminal failure eligibility cases")
        print("PASS: 16 cross-playlist transfer eligibility combinations")
        print("PASS: 16 cellular upgrade and in-progress import combinations")
        print("PASS: cellular, expensive and constrained network opt-in fixtures")
        print("PASS: background callback staged-file precedence fixtures")
        print("PASS: background download URL policy fixtures")
    }
}
