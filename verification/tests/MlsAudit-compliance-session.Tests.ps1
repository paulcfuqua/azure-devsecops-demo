# Connect-MlsCompliance - the L4 Security & Compliance session.
#
# WHY THIS FILE EXISTS
#
# This function had no test of any kind. Every suite that reaches L4 mocks it away
# (`Mock Connect-MlsCompliance {}` in layer-04-audit.Tests.ps1), which is right for those
# suites - they are testing criteria, not transport - but it meant the one line that
# actually opens the session was asserted by nothing, anywhere.
#
# It was also wrong, and had been for the life of the project:
#
#     Connect-IPPSSession -AppId $AppId -Organization $Organization -CertificateThumbprint $CertificateThumbprint
#
# `-CertificateThumbprint` is a WINDOWS-ONLY DYNAMIC PARAMETER of Connect-IPPSSession. The
# ExchangeOnlineManagement module builds its certificate parameters in a DynamicParam block
# and adds that one only inside `if($IsWindows)`, with the comment "We do not want to
# expose certificate thumprint in Linux as it is not feasible there." CI is ubuntu-latest,
# so the call died at parameter binding - "A parameter cannot be found that matches
# parameter name 'CertificateThumbprint'" - before it opened a connection, and the audit
# exited 2 having recorded no criterion (F172).
#
# Nobody saw it because the job that runs the audit had never once executed: its credential
# guard read `secrets.MLS_VERIFIER_CERT_BASE64` from a job declaring `environment: demo`
# while that secret lives on `verify`, so the guard reported "not configured" and the job
# skipped green on every run in the repository's history (F170/F171).
#
# THE WORKING IMPLEMENTATION WAS ALREADY IN THE REPO. L4's apply job connects to the same
# service on the same runner with -Certificate / -CertificateFilePath, which the module
# adds unconditionally, and it has always worked. The fix is that path.
#
# The Linux case is simulated by STUBBING Connect-IPPSSession with a parameter set that
# omits CertificateThumbprint, which is exactly what the module presents there. That is the
# only honest way to test a platform gate from a Windows dev box, and it is what makes
# these tests fail on the old implementation rather than merely exercise the new one.

BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'MlsAudit.psm1') -Force
    # No Set-StrictMode -Off: the audit scripts set -Version Latest and CI runs them that
    # way, so the harness must not relax the language mode it is testing (F49).

    # THE STUB IS DEFINED UNCONDITIONALLY, AND THAT IS THE POINT.
    #
    # Pester cannot mock a command that does not exist, and the lint job installs
    # PSScriptAnalyzer, Pester and SqlServer - not ExchangeOnlineManagement. So the first
    # version of this file passed on a Windows box with the real module installed and
    # failed all nine on ubuntu-latest with "Could not find Command Connect-IPPSSession":
    # a test about a platform-gated parameter that was itself platform-dependent, which is
    # the same shape as the defect it exists to pin.
    #
    # Defining it inside the MODULE's session state - where Connect-MlsCompliance resolves
    # its commands - makes every run identical on every platform and independent of whether
    # the real module happens to be installed. The parameter set here is the LINUX one
    # (no CertificateThumbprint); the Windows context below re-stubs it with that parameter
    # added, so both platforms are exercised everywhere rather than one being exercised
    # wherever the suite happens to run.
    # Set-Item on the function: drive, NOT a bare `function` keyword. InModuleScope runs
    # its scriptblock in a CHILD scope of the module, so a plain definition evaporates the
    # moment it returns and Mock still reports "Could not find Command". Writing
    # function:script: puts it in the module's own script scope, where it persists and
    # where Connect-MlsCompliance resolves.
    InModuleScope MlsAudit {
        Set-Item -Path 'function:script:Connect-IPPSSession' -Value {
            param($AppId, $Organization, $Certificate, $CertificateFilePath,
                [SecureString]$CertificatePassword, $ShowBanner)
            # Referenced so the parameters are not 'unused': this stub exists to declare a
            # parameter SET - which names Connect-IPPSSession will and will not bind on a
            # given platform - and has deliberately no behaviour. CertificatePassword is
            # typed SecureString because that is what the real cmdlet takes.
            $null = $AppId, $Organization, $Certificate, $CertificateFilePath,
                $CertificatePassword, $ShowBanner
        }
    }

    $script:Root = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-scc-$([guid]::NewGuid().ToString('n'))"
    New-Item -ItemType Directory -Path $script:Root -Force | Out-Null

    # A real PFX, generated in-memory: the password branch builds an X509Certificate2 from
    # the file, so a fixture of arbitrary bytes would test the branch and not the parsing.
    $script:CertPassword = 'p@ssw0rd-for-a-test-only'
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=mls-verifier-test', $rsa,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $cert = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(30))
    $script:ProtectedPfx = Join-Path $script:Root 'protected.pfx'
    [IO.File]::WriteAllBytes($script:ProtectedPfx, $cert.Export(
            [System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $script:CertPassword))
    $script:PlainPfx = Join-Path $script:Root 'plain.pfx'
    [IO.File]::WriteAllBytes($script:PlainPfx, $cert.Export(
            [System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx))
}

AfterAll {
    if (Test-Path -LiteralPath $script:Root) {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Connect-MlsCompliance' {

    BeforeEach {
        # Assert-MlsCommand would refuse before any of this on a box without the real
        # module; the stub below is what these tests are actually about.
        Mock Assert-MlsCommand {} -ModuleName 'MlsAudit'
        $script:Captured = $null
    }

    Context 'on Linux, where Connect-IPPSSession has no -CertificateThumbprint' {

        BeforeEach {
            # The module's Linux parameter set: Certificate/CertificateFilePath/
            # CertificatePassword present, CertificateThumbprint ABSENT.
            Mock Connect-IPPSSession {
                $script:Captured = $PSBoundParameters
            } -ModuleName 'MlsAudit' -ParameterFilter { $true }
            Mock Get-Command {
                return [pscustomobject]@{
                    Parameters = @{
                        AppId               = $null
                        Organization        = $null
                        Certificate         = $null
                        CertificateFilePath = $null
                        CertificatePassword = $null
                        ShowBanner          = $null
                    }
                }
            } -ModuleName 'MlsAudit' -ParameterFilter { $Name -eq 'Connect-IPPSSession' }
        }

        It 'connects with -CertificateFilePath when the PFX has no password' {
            InModuleScope MlsAudit -Parameters @{ Pfx = $script:PlainPfx } {
                param($Pfx)
                Connect-MlsCompliance -Organization 'contoso.onmicrosoft.com' -AppId 'app-1' -CertificateFilePath $Pfx
            }
            Should -Invoke Connect-IPPSSession -ModuleName 'MlsAudit' -Exactly -Times 1 -ParameterFilter {
                $CertificateFilePath -and -not $PSBoundParameters.ContainsKey('CertificateThumbprint')
            }
        }

        It 'builds an X509Certificate2 and passes -Certificate when the PFX is password-protected' {
            # Mirrors L4's apply job exactly: -CertificateFilePath alone cannot carry a
            # password, so the proven path constructs the certificate itself.
            InModuleScope MlsAudit -Parameters @{ Pfx = $script:ProtectedPfx; Pw = $script:CertPassword } {
                param($Pfx, $Pw)
                Connect-MlsCompliance -Organization 'contoso.onmicrosoft.com' -AppId 'app-1' `
                    -CertificateFilePath $Pfx -CertificatePassword $Pw
            }
            Should -Invoke Connect-IPPSSession -ModuleName 'MlsAudit' -Exactly -Times 1 -ParameterFilter {
                $Certificate -is [System.Security.Cryptography.X509Certificates.X509Certificate2] -and
                -not $PSBoundParameters.ContainsKey('CertificateThumbprint')
            }
        }

        It 'NEVER passes -CertificateThumbprint, which is what broke the audit' {
            # The regression itself. On the old implementation this parameter was passed
            # unconditionally and PowerShell failed to bind it.
            InModuleScope MlsAudit -Parameters @{ Pfx = $script:PlainPfx } {
                param($Pfx)
                Connect-MlsCompliance -Organization 'contoso.onmicrosoft.com' -AppId 'app-1' `
                    -CertificateFilePath $Pfx -CertificateThumbprint 'C2B0CDB6E8ECB82AFB00A059AFAD657AECEB6F38'
            }
            Should -Invoke Connect-IPPSSession -ModuleName 'MlsAudit' -Exactly -Times 1 -ParameterFilter {
                -not $PSBoundParameters.ContainsKey('CertificateThumbprint')
            }
        }

        It 'refuses a thumbprint-only call with a message naming the fix, not a binding error' {
            # An adopter who sets only MLS_VERIFIER_CERT gets told what to do instead of
            # "A parameter cannot be found that matches parameter name", which names the
            # symptom and hides both the platform gate and the working alternative.
            {
                InModuleScope MlsAudit {
                    Connect-MlsCompliance -Organization 'contoso.onmicrosoft.com' -AppId 'app-1' `
                        -CertificateThumbprint 'C2B0CDB6E8ECB82AFB00A059AFAD657AECEB6F38'
                }
            } | Should -Throw '*Windows-only dynamic parameter*'
        }

        It 'refuses a thumbprint-only call by naming -CertificateFilePath as the fix' {
            {
                InModuleScope MlsAudit {
                    Connect-MlsCompliance -Organization 'contoso.onmicrosoft.com' -AppId 'app-1' `
                        -CertificateThumbprint 'C2B0CDB6E8ECB82AFB00A059AFAD657AECEB6F38'
                }
            } | Should -Throw '*-CertificateFilePath*'
        }
    }

    Context 'on Windows, where -CertificateThumbprint exists' {

        BeforeEach {
            # RE-STUBBED WITH THE WINDOWS PARAMETER SET, so this context exercises a
            # command that can actually bind -CertificateThumbprint. Without this the
            # stub above (deliberately missing it, as Linux is) would be the thing under
            # test here too, and a passing assertion would prove nothing about Windows.
            InModuleScope MlsAudit {
                Set-Item -Path 'function:script:Connect-IPPSSession' -Value {
                    param($AppId, $Organization, $Certificate, $CertificateFilePath,
                        [SecureString]$CertificatePassword, $CertificateThumbprint, $ShowBanner)
                    # Referenced so the parameters are not 'unused': this stub exists to declare a
                    # parameter SET - which names Connect-IPPSSession will and will not bind on a
                    # given platform - and has deliberately no behaviour. CertificatePassword is
                    # typed SecureString because that is what the real cmdlet takes.
                    $null = $AppId, $Organization, $Certificate, $CertificateFilePath,
                        $CertificatePassword, $CertificateThumbprint, $ShowBanner
                }
            }
            Mock Connect-IPPSSession { $script:Captured = $PSBoundParameters } -ModuleName 'MlsAudit'
            Mock Get-Command {
                return [pscustomobject]@{
                    Parameters = @{
                        AppId                 = $null
                        Organization          = $null
                        Certificate           = $null
                        CertificateFilePath   = $null
                        CertificatePassword   = $null
                        CertificateThumbprint = $null
                        ShowBanner            = $null
                    }
                }
            } -ModuleName 'MlsAudit' -ParameterFilter { $Name -eq 'Connect-IPPSSession' }
        }

        It 'still accepts a thumbprint, so a local Windows run is not broken by the fix' {
            InModuleScope MlsAudit {
                Connect-MlsCompliance -Organization 'contoso.onmicrosoft.com' -AppId 'app-1' `
                    -CertificateThumbprint 'C2B0CDB6E8ECB82AFB00A059AFAD657AECEB6F38'
            }
            Should -Invoke Connect-IPPSSession -ModuleName 'MlsAudit' -Exactly -Times 1 -ParameterFilter {
                $CertificateThumbprint -eq 'C2B0CDB6E8ECB82AFB00A059AFAD657AECEB6F38'
            }
        }

        It 'prefers the file over the thumbprint when both are supplied' {
            # CI supplies the file; a stale MLS_VERIFIER_CERT left in an environment must
            # not be able to steer the session back onto the platform-gated path.
            InModuleScope MlsAudit -Parameters @{ Pfx = $script:PlainPfx } {
                param($Pfx)
                Connect-MlsCompliance -Organization 'contoso.onmicrosoft.com' -AppId 'app-1' `
                    -CertificateFilePath $Pfx -CertificateThumbprint 'C2B0CDB6E8ECB82AFB00A059AFAD657AECEB6F38'
            }
            Should -Invoke Connect-IPPSSession -ModuleName 'MlsAudit' -Exactly -Times 1 -ParameterFilter {
                $CertificateFilePath -and -not $PSBoundParameters.ContainsKey('CertificateThumbprint')
            }
        }
    }

    Context 'inputs that cannot open a session' {

        BeforeEach {
            # Back to the Linux parameter set: the Windows context above replaced the
            # module-scope stub, and a context that inherited it would be testing a
            # different command from the one it names.
            InModuleScope MlsAudit {
                Set-Item -Path 'function:script:Connect-IPPSSession' -Value {
                    param($AppId, $Organization, $Certificate, $CertificateFilePath,
                        [SecureString]$CertificatePassword, $ShowBanner)
                    # Referenced so the parameters are not 'unused': this stub exists to declare a
                    # parameter SET - which names Connect-IPPSSession will and will not bind on a
                    # given platform - and has deliberately no behaviour. CertificatePassword is
                    # typed SecureString because that is what the real cmdlet takes.
                    $null = $AppId, $Organization, $Certificate, $CertificateFilePath,
                        $CertificatePassword, $ShowBanner
                }
            }
            Mock Connect-IPPSSession {} -ModuleName 'MlsAudit'
            Mock Get-Command {
                return [pscustomobject]@{ Parameters = @{ CertificateFilePath = $null } }
            } -ModuleName 'MlsAudit' -ParameterFilter { $Name -eq 'Connect-IPPSSession' }
        }

        It 'refuses when no certificate of any kind is supplied' {
            {
                InModuleScope MlsAudit {
                    Connect-MlsCompliance -Organization 'contoso.onmicrosoft.com' -AppId 'app-1'
                }
            } | Should -Throw '*needs a certificate*'
            Should -Invoke Connect-IPPSSession -ModuleName 'MlsAudit' -Exactly -Times 0
        }

        It 'names the missing file rather than letting the module report a parse failure' {
            # A staging step that did not run, or a RUNNER_TEMP path that moved, is a
            # legible precondition failure - not "the PFX could not be decoded".
            {
                InModuleScope MlsAudit {
                    Connect-MlsCompliance -Organization 'contoso.onmicrosoft.com' -AppId 'app-1' `
                        -CertificateFilePath '/nonexistent/mls-verifier.pfx'
                }
            } | Should -Throw '*does not exist*'
            Should -Invoke Connect-IPPSSession -ModuleName 'MlsAudit' -Exactly -Times 0
        }
    }
}
