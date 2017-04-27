# frozen_string_literal: true
#
# Copyright (C) 2014-2016 Harald Sitter <sitter@kde.org>
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) version 3, or any
# later version accepted by the membership of KDE e.V. (or its
# successor approved by the membership of KDE e.V.), which shall
# act as a proxy defined in Section 6 of version 3 of the license.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library.  If not, see <http://www.gnu.org/licenses/>.

require_relative 'test_helper'

class GitSemaphoreTest < Minitest::Test
  METHOD_BACKUP = :__kill_orig
  METHOD = :kill

  def simpulate_process_dead(&block)
    class << Process
      alias_method METHOD_BACKUP, METHOD
      def kill(*)
        puts 'Intercepted Process.kill ⇒ Raising'
        raise ''
      end
    end
    yield
  ensure
    class << Process
      alias_method METHOD, METHOD_BACKUP
    end
  end

  def simpulate_process_alive(&block)
    class << Process
      alias_method METHOD_BACKUP, METHOD
      def kill(*)
        puts 'Intercepted Process.kill ⇒ NOT raising'
      end
    end
    yield
  ensure
    class << Process
      alias_method METHOD, METHOD_BACKUP
    end
  end

  def test_init
    s = Semaphore.new
    assert_equal(s.class::HOSTS, s.host_semaphores.keys)
    s.host_semaphores.each do |host, sem|
      assert_equal(sem.class::MAX_LOCKS, sem.locks.size,
                   "Size of locks for host #{host} incorrect.")
    end
  end

  def test_sync
    s = Semaphore.new
    host = :debian
    s.synchronize(1, host) do
      assert_includes(s.host_semaphores[host].locks, 1)
    end
    refute_includes(s.host_semaphores[host].locks, 1)
  end

  def test_cleanup
    s = Semaphore.new
    host = :debian
    # We are going to release the lock while the block is still running
    # this is expected to raise a release error on account of us not having
    # terminated properly.
    simpulate_process_dead do
      assert_raises HostSemaphore::LockReleaseError do
        s.synchronize(1, host) do
          # Attempt to sync again. This should now kill our previous lock.
          s.synchronize(2, host) do
            refute_includes(s.host_semaphores[host].locks, 1)
            assert_includes(s.host_semaphores[host].locks, 2)
          end
          refute_includes(s.host_semaphores[host].locks, 1)
          refute_includes(s.host_semaphores[host].locks, 2)
        end
      end
      # This assert applies after the release has raised.
      refute_includes(s.host_semaphores[host].locks, 1)
    end
  end

  def test_logging
    log_path = "#{Dir.pwd}/log"
    logger = Logger.new(log_path)

    s = Semaphore.new
    s.instance_variable_set(:@log, logger)
    s.host_semaphores.each do |_, sem|
      sem.instance_variable_set(:@log, logger)
    end
    s.enable_logging
    s.log_locks

    assert(File.exist?(log_path))
    refute_equal('', File.read(log_path))
    assert(File.read(log_path).lines.size > s.host_semaphores.size)
  end

  def test_process_running
    s = Semaphore.new
    host = :debian
    simpulate_process_alive do
      s.synchronize(1, host) do
        s.log_locks # Cleans up as well
        assert_includes(s.host_semaphores[host].locks, 1)
      end
      refute_includes(s.host_semaphores[host].locks, 1)
    end
  end

  def assert_single_lock(semaphore, pid, host)
    s = semaphore
    s.synchronize(pid, host) do
      locks = s.host_semaphores[host].locks.dup
      assert_equal(s.host_semaphores[host].class::MAX_LOCKS, locks.size)
      locks.delete_if(&:nil?)
      assert_equal(1, locks.size)
      assert_equal(locks[0], pid)
      yield if block_given?
    end
  end

  def test_host_separation
    # Each host is supposed to have their own lock pool as it were.
    s = Semaphore.new
    assert_single_lock(s, 1, :debian) do
      assert_single_lock(s, 2, :kde)
    end
  end
end
