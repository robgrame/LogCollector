@{
    PackageVersion = '1.7.1'
    Environment = ''
    # Names the %ProgramData%\<CustomerName>\<ApplicationName>\Logs tree that Write-CMTraceLog
    # writes to, so every script on the device logs under one predictable folder. Empty falls
    # back to 'LogCollector'.
    CustomerName = ''
    # The package builder supplies the endpoint; an empty value fails the install by design,
    # so a package can never ship pointing nowhere.
    FrontendUrl = ''
    # Scripts may submit as soon as the core package is installed. Set to $false to stage the
    # module across the fleet before the server-side table mappings are ready.
    SubmissionEnabled = $true
    CertificateThumbprint = ''
    CertificateSubjectLike = ''
    CertificateIssuerLike = ''
    PkiRootCaThumbprints = @()
    PkiRootCaSubjects = @()
    PkiIntermediateCaThumbprints = @()
    PkiIntermediateCaSubjects = @()
}
