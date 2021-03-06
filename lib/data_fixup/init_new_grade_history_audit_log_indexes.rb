#
# Copyright (C) 2017 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

module DataFixup
  class InitNewGradeHistoryAuditLogIndexes

    def self.run
      new.build_indexes
    end

    SEARCH_CQL = %{
      SELECT id, created_at, context_id, assignment_id, grader_id, student_id
      FROM grade_changes
      WHERE token(id) > token(?)
      LIMIT ?
    }.freeze

    INDEX_METHODS = [
      :add_course_assignment_index,
      :add_course_assignment_grader_index,
      :add_course_assignment_grader_student_index,
      :add_course_assignment_student_index,
      :add_course_grader_index,
      :add_course_grader_student_index,
      :add_course_student_index
    ].freeze

    READ_BATCH_SIZE = 1000
    WRITE_BATCH_SIZE = 400

    def build_indexes
      new_index_entries = []
      last_seen_id = nil
      done = false
      until done
        done, last_seen_id = read_and_process_batch(last_seen_id, new_index_entries)
      end
      write_batch(new_index_entries)
    end

    private

    def read_and_process_batch(starting_key, index_entries)
      last_id = nil
      result = database.execute(SEARCH_CQL, starting_key, READ_BATCH_SIZE)
      return true, nil if result.rows == 0
      result.fetch do |row|
        last_id = row['id']
        INDEX_METHODS.each do |method|
          result = self.send(method, row)
          index_entries << result if result
        end
      end
      write_in_batches(index_entries)
      return false, last_id
    end

    ResultStruct = Struct.new(:index, :record, :key)

    def write_in_batches(batch)
      while batch.size >= WRITE_BATCH_SIZE
        write_batch(batch.shift(WRITE_BATCH_SIZE))
      end
    end

    def write_batch(batch)
      return if batch.empty?
      database.batch { batch.each { |r| r.index.insert(r.record, r.key) } }
    end

    def database
      @database ||= Canvas::Cassandra::DatabaseBuilder.from_config(:auditors)
    end

    def add_course_assignment_index(row)
      index = Auditors::GradeChange::Stream.course_assignment_index
      key = [row['context_id'], row['assignment_id']]
      ResultStruct.new(index, OpenStruct.new(row.to_hash), key)
    end

    def add_course_assignment_grader_index(row)
      return unless row['grader_id']

      index = Auditors::GradeChange::Stream.course_assignment_grader_index
      key = [row['context_id'], row['assignment_id'], row['grader_id']]
      ResultStruct.new(index, OpenStruct.new(row.to_hash), key)
    end

    def add_course_assignment_grader_student_index(row)
      return unless row['grader_id']

      index = Auditors::GradeChange::Stream.course_assignment_grader_student_index
      key = [row['context_id'], row['assignment_id'], row['grader_id'], row['student_id']]
      ResultStruct.new(index, OpenStruct.new(row.to_hash), key)
    end

    def add_course_assignment_student_index(row)
      index = Auditors::GradeChange::Stream.course_assignment_student_index
      key = [row['context_id'], row['assignment_id'], row['student_id']]
      ResultStruct.new(index, OpenStruct.new(row.to_hash), key)
    end

    def add_course_grader_index(row)
      return unless row['grader_id']

      index = Auditors::GradeChange::Stream.course_grader_index
      key = [row['context_id'], row['grader_id']]
      ResultStruct.new(index, OpenStruct.new(row.to_hash), key)
    end

    def add_course_grader_student_index(row)
      return unless row['grader_id']

      index = Auditors::GradeChange::Stream.course_grader_student_index
      key = [row['context_id'], row['grader_id'], row['student_id']]
      ResultStruct.new(index, OpenStruct.new(row.to_hash), key)
    end

    def add_course_student_index(row)
      index = Auditors::GradeChange::Stream.course_student_index
      key = [row['context_id'], row['student_id']]
      ResultStruct.new(index, OpenStruct.new(row.to_hash), key)
    end
  end
end
