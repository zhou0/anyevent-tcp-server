package AnyEvent::TCP::Server::LoggerWorker;

use strict;
use IO::Socket::INET;
use Carp;
use AnyEvent::TCP::Server::Utils;
use AnyEvent::TCP::Server::AbstractWorker;
use base qw/AnyEvent::TCP::Server::AbstractWorker/;

# $| = 1;
use AnyEvent::TCP::Server::Log qw/init_logger log_conf/;
my $FH;

sub spawn {
    my ($self, %params) = @_;

    dbg_msg "Spawning logger worker.";
    unless ($params{filename}) {
        croak "Can't spawn log worker without logfile parameter!";
    }

    my $logfile = $params{filename};

    my $open_mode = '>';
    if ($params{append}) {
        $open_mode = '>>';
    }

    return $self->SUPER::spawn(
        type        => 'logger_worker',
        number      =>  $params{number},
        procname    =>  $params{procname},
        worker_does => sub {
            my ($self) = @_;
            if ($params{worker_does}) {
                my $sub = $params{worker_does};
                $sub->($self);
            }
            $self->{logger} = init_logger();
        },
        run         => sub {
            my ($self) = @_;
            

            $SIG{INT} ='DEFAULT';
            $SIG{TERM} = 'DEFAULT';
            dbg_msg "Gonna run logger";
            open $FH, $open_mode, $logfile;
            $FH->autoflush();
            while (my $log_chunk = $self->{logger}->recv()) {
                dbg_msg "Logger worker accepting log string:\n $log_chunk\n";
                print $FH $log_chunk or carp "Error: $!";
            }
        },
        master_does => sub {
            my ($self) = @_;
            return $self;
        },
    );
}


1;
