# PSScriptAnalyzer settings, picked up automatically when the repo root is analyzed.
# These exclusions are deliberate choices for a small interactive build tool, not
# blanket silencing. Everything else stays on.
@{
    ExcludeRules = @(
        # This is a console tool. Write-Host is how it talks to the operator.
        'PSAvoidUsingWriteHost',
        # The VM lifecycle helpers change state by design and are not meant to be
        # piped or used with -WhatIf, so ShouldProcess plumbing would be noise.
        'PSUseShouldProcessForStateChangingFunctions',
        # The console screenshot uses the Msvm thumbnail WMI class, which has no
        # clean CIM equivalent for this call.
        'PSAvoidUsingWMICmdlet',
        # A couple of helpers read better with plural nouns (credentials, keys).
        'PSUseSingularNouns'
    )
}
