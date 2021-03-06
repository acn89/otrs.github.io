# --
# Copyright (C) 2001-2016 OTRS AG, http://otrs.com/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (AGPL). If you
# did not receive this file, see http://www.gnu.org/licenses/agpl.txt.
# --

package Kernel::System::Auth;

use strict;
use warnings;

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::Group',
    'Kernel::System::Log',
    'Kernel::System::Main',
    'Kernel::System::SystemMaintenance',
    'Kernel::System::Time',
    'Kernel::System::User',
    'Kernel::System::Valid',
);

=head1 NAME

Kernel::System::Auth - agent authentication module.

=head1 SYNOPSIS

The authentication module for the agent interface.

=head1 PUBLIC INTERFACE

=over 4

=cut

=item new()

create an object. Do not use it directly, instead use:

    use Kernel::System::ObjectManager;
    local $Kernel::OM = Kernel::System::ObjectManager->new();
    my $AuthObject = $Kernel::OM->Get('Kernel::System::Auth');

=cut

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    # get needed objects
    my $MainObject   = $Kernel::OM->Get('Kernel::System::Main');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    # load auth modules
    COUNT:
    for my $Count ( '', 1 .. 10 ) {

        my $GenericModule = $ConfigObject->Get("AuthModule$Count");

        next COUNT if !$GenericModule;

        if ( !$MainObject->Require($GenericModule) ) {
            $MainObject->Die("Can't load backend module $GenericModule! $@");
        }

        $Self->{"AuthBackend$Count"} = $GenericModule->new( Count => $Count );
    }

    # load sync modules
    COUNT:
    for my $Count ( '', 1 .. 10 ) {

        my $GenericModule = $ConfigObject->Get("AuthSyncModule$Count");

        next COUNT if !$GenericModule;

        if ( !$MainObject->Require($GenericModule) ) {
            $MainObject->Die("Can't load backend module $GenericModule! $@");
        }

        $Self->{"AuthSyncBackend$Count"} = $GenericModule->new( %{$Self}, Count => $Count );
    }

    # Initialize last error message
    $Self->{LastErrorMessage} = '';

    return $Self;
}

=item GetOption()

Get module options. Currently there is just one option, "PreAuth".

    if ( $AuthObject->GetOption( What => 'PreAuth' ) ) {
        print "No login screen is needed. Authentication is based on some other options. E. g. $ENV{REMOTE_USER}\n";
    }

=cut

sub GetOption {
    my ( $Self, %Param ) = @_;

    return $Self->{AuthBackend}->GetOption(%Param);
}

=item Auth()

The authentication function.

    if ( $AuthObject->Auth( User => $User, Pw => $Pw ) ) {
        print "Auth ok!\n";
    }
    else {
        print "Auth invalid!\n";
    }

=cut

sub Auth {
    my ( $Self, %Param ) = @_;

    # get needed objects
    my $UserObject   = $Kernel::OM->Get('Kernel::System::User');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    # use all 11 auth backends and return on first true
    my $User;
    COUNT:
    for my $Count ( '', 1 .. 10 ) {

        # return on no config setting
        next COUNT if !$Self->{"AuthBackend$Count"};

        # check auth backend
        $User = $Self->{"AuthBackend$Count"}->Auth(%Param);

        # next on no success
        next COUNT if !$User;

        # configured auth sync backend
        my $AuthSyncBackend = $ConfigObject->Get("AuthModule::UseSyncBackend$Count");
        if ( !defined $AuthSyncBackend ) {
            $AuthSyncBackend = $ConfigObject->Get("AuthModule{$Count}::UseSyncBackend");
        }

        # for backwards compatibility, OTRS 3.1.1, 3.1.2 and 3.1.3 used this wrong format (see bug#8387)

        # sync with configured auth backend
        if ( defined $AuthSyncBackend ) {

            # if $AuthSyncBackend is defined but empty, don't sync with any backend
            if ($AuthSyncBackend) {

                # sync configured backend
                $Self->{$AuthSyncBackend}->Sync( %Param, User => $User );
            }
        }

        # use all 11 sync backends
        else {
            SOURCE:
            for my $Count ( '', 1 .. 10 ) {

                # return on no config setting
                next SOURCE if !$Self->{"AuthSyncBackend$Count"};

                # sync backend
                $Self->{"AuthSyncBackend$Count"}->Sync( %Param, User => $User );
            }
        }

        # remember auth backend
        my $UserID = $UserObject->UserLookup(
            UserLogin => $User,
        );

        if ($UserID) {
            $UserObject->SetPreferences(
                Key    => 'UserAuthBackend',
                Value  => $Count,
                UserID => $UserID,
            );
        }

        last COUNT if $User;
    }

    # return if no auth user
    if ( !$User ) {

        # remember failed logins
        my $UserID = $UserObject->UserLookup(
            UserLogin => $Param{User},
        );

        return if !$UserID;

        my %User = $UserObject->GetUserData(
            UserID => $UserID,
            Valid  => 1,
        );

        my $Count = $User{UserLoginFailed} || 0;
        $Count++;

        $UserObject->SetPreferences(
            Key    => 'UserLoginFailed',
            Value  => $Count,
            UserID => $UserID,
        );

        # set agent to invalid-temporarily if max failed logins reached
        my $Config = $ConfigObject->Get('PreferencesGroups');
        my $PasswordMaxLoginFailed;

        if ( $Config && $Config->{Password} && $Config->{Password}->{PasswordMaxLoginFailed} ) {
            $PasswordMaxLoginFailed = $Config->{Password}->{PasswordMaxLoginFailed};
        }

        return if !%User;
        return if !$PasswordMaxLoginFailed;
        return if $Count < $PasswordMaxLoginFailed;

        my $ValidID = $Kernel::OM->Get('Kernel::System::Valid')->ValidLookup(
            Valid => 'invalid-temporarily',
        );

        my $Update = $UserObject->UserUpdate(
            %User,
            ValidID      => $ValidID,
            ChangeUserID => 1,
        );

        return if !$Update;

        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'notice',
            Message  => "Login failed $Count times. Set $User{UserLogin} to "
                . "'invalid-temporarily'.",
        );

        return;
    }

    # remember login attributes
    my $UserID = $UserObject->UserLookup(
        UserLogin => $User,
    );

    return $User if !$UserID;

    # on system maintenance just admin users
    # should be allowed to get into the system
    my $ActiveMaintenance = $Kernel::OM->Get('Kernel::System::SystemMaintenance')->SystemMaintenanceIsActive();

    # reset failed logins
    $UserObject->SetPreferences(
        Key    => 'UserLoginFailed',
        Value  => 0,
        UserID => $UserID,
    );

    # check if system maintenance is active
    if ($ActiveMaintenance) {

        # check if user is allow to login
        # get current user groups
        my %Groups = $Kernel::OM->Get('Kernel::System::Group')->GroupMemberList(
            UserID => $UserID,
            Type   => 'move_into',
            Result => 'HASH',
        );

        # reverse groups hash for easy look up
        %Groups = reverse %Groups;

        # check if the user is in the Admin group
        # if that is not the case return
        if ( !$Groups{admin} ) {

            $Self->{LastErrorMessage} =
                $ConfigObject->Get('SystemMaintenance::IsActiveDefaultLoginErrorMessage')
                || "It is currently not possible to login due to a scheduled system maintenance.";

            return;
        }
    }

    # last login preferences update
    $UserObject->SetPreferences(
        Key    => 'UserLastLogin',
        Value  => $Kernel::OM->Get('Kernel::System::Time')->SystemTime(),
        UserID => $UserID,
    );

    return $User;
}

=item GetLastErrorMessage()

Retrieve $Self->{LastErrorMessage} content.

    my $AuthErrorMessage = $AuthObject->GetLastErrorMessage();

    Result:

        $AuthErrorMessage = "An error string message.";

=cut

sub GetLastErrorMessage {
    my ( $Self, %Param ) = @_;

    return $Self->{LastErrorMessage};
}

1;

=back

=head1 TERMS AND CONDITIONS

This software is part of the OTRS project (L<http://otrs.org/>).

This software comes with ABSOLUTELY NO WARRANTY. For details, see
the enclosed file COPYING for license information (AGPL). If you
did not receive this file, see L<http://www.gnu.org/licenses/agpl.txt>.

=cut
