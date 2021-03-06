package AnyEvent::TCP::Server::Master;

use strict;
##use warnings;

use Carp;
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use IO::FDPass;

use AnyEvent::TCP::Server::ProcessWorker;
use AnyEvent::TCP::Server::Utils;
use AnyEvent::TCP::Server::LoggerWorker;

use POSIX;


sub new {
    my ($class, $params) = @_;

    my $self = {
        _init_params        =>  $params,
        _workers            =>  {},
        assoc               =>  {},
        firstrun            =>  1,
        client_forwarding   =>  0,
        max_workers         =>  $params->{workers},
    };

    bless $self, $class;

    if ($self->{_init_params}->{procname}) {
        $self->{procname} = $self->{_init_params}->{procname} . ' master';
    }

    if ($self->{_init_params}->{client_forwarding}) {
        $self->{client_forwarding} = 1;
        # croak "Client forwarding disabled right now. Maybe, it will be available soon.";
    }

    if ($params->{check_on_connect}) {
        croak 'check_on_connect must be a CODE ref' if ref $params->{check_on_connect} ne 'CODE';
        no warnings 'redefine';
        *{AnyEvent::TCP::Server::Master::check_on_connect} = $params->{check_on_connect};
    }

    if ($self->{_init_params}->{_log}) {
        $self->{_log} = $self->{_init_params}->{_log};
    }
    
    return $self;
}


# internal sub, which prepares master to run.
sub prepare {
    my ($self) = @_;

    my $init_params = $self->init_params();
    if ($self->{firstrun}) {
        %{$self->{respawn}} = map {$_, 1} (1 .. $init_params->{workers});
    }

    $self->{firstrun} = 0;

    dbg_msg 'prepared for respawn: ', join (', ',  keys %{$self->{respawn}});
}

sub spawn_logger {
    my ($self) = @_;
    my $init_params = $self->init_params();
    if ($init_params->{_log}) {
        dbg_msg("Spawning logger");
        my $log_config = $init_params->{_log};

        if (!$log_config->{filename}) {
            croak "Bad parameters";
        }

        my $l = AnyEvent::TCP::Server::LoggerWorker->spawn(
            number              =>  1,
            procname            =>  $init_params->{procname},
            type                =>  'logger',
            append              =>  $log_config->{append},
            filename            =>  $log_config->{filename},
            port                =>  $log_config->{port},
            worker_does         =>  sub {
                # at first, if need, we should unloop.
                if ($self->{_cv}) {
                    undef $self->{_cv};
                }
                if ($self->{tcp_server_guard}) {
                    undef $self->{tcp_server_guard};
                }
            },
        );
        dbg_msg "[$$]Logger spawned with pid: $l->{pid}";
        $self->{_logger_worker} = [];
        push @{$self->{_logger_worker}}, $l;
        $self->set_logger_watcher();
    }

}
# main function
sub run {
    my ($self) = @_;

    $self->{_cv} = AnyEvent->condvar();

    procname $self->{procname};
    
    my $init_params = $self->init_params();

    $self->{workers_count} = 0;

    # Log process spawning
    $init_params->{procname} ||= 'AE::TCP::Server';
    # Worker processes spawning
    for my $key (sort {$a <=> $b} keys %{$self->{respawn}}) {
        dbg_msg "spawning worker: $key\n";
        # key will become worker number
        # my $w = AnyEvent::TCP::Server::Worker->spawn($init_params, $key);

        my $w = AnyEvent::TCP::Server::ProcessWorker->spawn(
            process_request     =>  $init_params->{process_request},
            number              =>  $key,
            procname            =>  $init_params->{procname},
            client_forwarding   =>  $self->{client_forwarding},
        );
        $self->add_worker($w, $key);
        $self->numerate($w->{pid}, $key);
    }
    
    unless ($self->{RESPAWN_ONLY_PROCESS_WORKERS}) {
        eval {
            $self->spawn_logger();
            1;
        } or do {
            dbg_msg "Error occured during logger respawn: $@";
        };
    }
    $self->{RESPAWN_ONLY_PROCESS_WORKERS} = 1;

    dbg_msg "Workers spawned";

    # clean respawn hash, before we start
    $self->{respawn} = {};

    # set sigterm handler
    $self->{sigterm} = undef;
    $self->{sigterm} = AnyEvent->signal(
        signal  =>  'TERM',
        cb      =>  sub {
            $self->process_signal('TERM');
            exit 1;
        },
    );


    # set sigint handler
    $self->{sigint} = undef;
    $self->{sigint} = AnyEvent->signal(
        signal  =>  'INT',
        cb      =>  sub {
            $self->process_signal('INT');
            exit 1;
        },
    );

    # set child watchers
    $self->set_watchers();

    eval {
        # start connection manager
        $self->{tcp_server_guard} = tcp_server undef, $init_params->{port}, sub {
            my ($fh, $host, $port) = @_;

            # call user's on_connect callback
            my $resp = check_on_connect($fh, $host, $port);

            unless ($resp) {
                $fh->close();
                return $resp;
            }

            dbg_msg "Connection accepted";
            
            # get current worker, for request processing
            my $current_worker = $self->next_worker();
            my $cw = $current_worker;

            dbg_msg "Next worker choosed: $self->{next_worker_number}";

            my $s = $cw->{writer};

            # additional data right now.
            IO::FDPass::send fileno $s, fileno $fh or croak $!;
        };
        1;
    } or do {
        # master died, let's reap children
        $self->reap_children();
        croak "Error occured: $@\n";
    };
    
    my $cmd = $self->{_cv}->recv();
    $self->{_cv} = undef;
    $self->{tcp_server_guard} = undef;

    # will respawn
    if ($cmd eq 'RESPAWN') {
        # as I know, only way to destroy custom signals handler
        $SIG{INT} = $SIG{TERM} = 'DEFAULT';

        # this sub is recursive because I can't fork active state machine.
        $self->run();
    }
    else {
        $self->reap_children();
        exit 1;
    }
}


# Next worker function, rount-robin principle
sub next_worker {
    my ($self) = @_;

    if (!$self->{next_worker_number}) {
        $self->{next_worker_number} = 1;
        return $self->get_worker(1);
    }

    $self->{next_worker_number}++;

    if ($self->{next_worker_number} > $self->{max_workers}) {
        delete $self->{next_worker_number};
        return $self->next_worker();
    }

    return $self->get_worker($self->{next_worker_number});
}


sub set_logger_watcher {
    my ($self) = @_;
    
    if ($self->{_logger_worker} && scalar @{$self->{_logger_worker}}) {
        my $lw = $self->{_logger_worker}->[0];
        $self->{log_watcher} = AnyEvent->child(
            pid     =>  $lw->{pid},
            cb      =>  sub {
                dbg_msg "Logger died. Respawning.";
                $self->spawn_logger();
            },
        );
    }
    return 1;
}


sub set_watchers {
    my ($self) = @_;
    
    my $workers = $self->{_workers};
    my $init_params = $self->{_init_params};

    $self->{watchers} = {};

    for my $w (values %{$self->{_workers}}) {
        my $worker_no = $w->worker_no();
        # set watcher by number
        $self->{watchers}->{$worker_no} = AnyEvent->child(
            pid => $w->{pid},
            cb  => sub {
                # runtime error
                if ($_[1] == 3328) {
                    dbg_msg "Compile time error. Shut down";
                    $self->reap_children();
                    exit 0;
                }
                # bind error
                elsif ($_[1] == 25088) {
                    dbg_msg 'bind error';
                    $self->reap_children();
                    exit 0;
                }

                # this conscturction created for killall handling.
                undef $self->{timer};
                # when child dies, timer starts and after time respawn comand
                # will be sent
                $self->{timer} = AnyEvent->timer(
                    after   =>  0.1,
                    cb      =>  sub {
                        dbg_msg("Workers for respawn: ", join (', ', keys %{ $self->{respawn}}));
                        #dbg_msg "Workers for respawn: ", join ', ' , @{$self->{respawn}};
                        $self->{_cv}->send('RESPAWN');
                    }
                );

                # set workers for respawn
                my $number = $self->number($w->{pid});
                $self->{respawn}->{$number} = 1;
                dbg_msg "Process with $w->{pid} died";
            },
        );
    }
}


sub process_signal {
    my ($self, $signal) = @_;

    $self->reap_children();
    return 1;
}


sub reap_children {
    my ($self) = @_;

    dbg_msg "Reaper is coming.";
    for my $w (values %{$self->{_workers}}) {
        dbg_msg "[$$]: Reaping: $w->{pid}!";
        kill POSIX::SIGTERM, $w->{pid};
    }
    for my $w (@{$self->{_logger_worker}}) {
        dbg_msg "[$$]: Reaping logger: ", $w->pid(), "\n";
        kill POSIX::SIGTERM, $w->pid();
    }
    return 1;
}


sub init_params {
    my ($self, $params) = @_;

    unless ($params) {
        return $self->{_init_params}
    }

    $self->{_init_params} = $params;
    return $params;
}


sub add_worker {
    my ($self, $worker, $number) = @_;

    if (!$worker || !$number) {
        croak 'Missing params for add_worker subroutine';
    }
    
    $self->{_workers}->{$number} = $worker;
}


sub get_worker {
    my ($self, $number) = @_;

    croak 'Missing argument for get_worker' unless $number;

    return $self->{_workers}->{$number};
}


sub numerate {
    my ($self, $pid, $number) = @_;

    $self->{_pids}->{$pid} = $number;
    $self->{_numbers}->{$number} = $pid;
    return 1;
}


sub denumerate {
    my ($self, $pid) = @_;

    delete $self->{_pids}->{$pid};
    return 1;
}


sub number {
    my ($self, $pid) = @_;

    return $self->{_pids}->{$pid};
}


sub pid {
    my ($self, $number) = @_;

    return $self->{_numbers}->{$number};
}


sub check_on_connect {
    return 1;
}


# TODO: add new spawn mechanism for workers
sub spawn_workers {
    1;
}

1;


__END__
