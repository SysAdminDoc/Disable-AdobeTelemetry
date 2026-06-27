@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSAvoidAssignmentToAutomaticVariable'
        'PSAvoidUsingEmptyCatchBlock'
        'PSUseSingularNouns'
        'PSUseBOMForUnicodeEncodedFile'
    )
}
