# frozen_string_literal: true

# == Schema Information
#
# Table name: districts
#
#  id                         :bigint           not null, primary key
#  allris_base_url            :string
#  first_legislation_number   :string
#  name                       :string
#  oldest_allris_meeting_date :date
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#  oldest_allris_document_id  :integer
#
require 'net/http'

class District < ApplicationRecord
  ALLRIS_DOCUMENT_UPDATES_URL = '/bi/vo040.asp'
  ALLRIS_MEETING_UPDATES_URL = '/bi/si010_e.asp' # ?MM=12&YY=2020

  # OLDEST_ALLRIS_ID = 1007791 # 1.1.2019 HH-Nord

  has_many :documents, dependent: :destroy
  has_many :meetings, dependent: :destroy
  has_many :agenda_items, through: :meetings
  has_many :committees, dependent: :destroy

  validates :name, presence: true
  validates :allris_base_url, presence: true

  scope :by_name, -> { order(:name) }

  def to_param
    name.parameterize
  end

  def self.lookup(path)
    @districts ||= District.all.index_by { |d| d.name.parameterize }

    @districts[path.parameterize]
  end

  def check_for_document_updates
    source = Net::HTTP.get(URI(allris_base_url + ALLRIS_DOCUMENT_UPDATES_URL))
    html = Nokogiri::HTML.parse(source.force_encoding('ISO-8859-1'))

    latest_link = html.css('tr.zl12 a').first['href']
    current_allris_id = (latest_link[/VOLFDNR=(\d+)/, 1]).to_i

    latest_allris_id = [oldest_allris_document_id, documents.maximum(:allris_id) || 0].max

    while current_allris_id > latest_allris_id
      document = documents.find_or_create_by!(allris_id: current_allris_id)
      UpdateDocumentJob.perform_later(document)

      current_allris_id -= 1
    end
  end

  def check_for_meeting_updates
    oldest_meeting_date = ([oldest_allris_meeting_date, meetings.complete.maximum(:date) || 10.years.ago].max - 1.month).beginning_of_month

    current_date = 6.months.from_now.beginning_of_month

    while current_date >= oldest_meeting_date
      check_for_meetings_in_month(current_date)

      current_date -= 1.month
    end
  end

  def check_for_meetings_in_month(month)
    source = Net::HTTP.get(URI(allris_base_url + ALLRIS_MEETING_UPDATES_URL + "?MM=#{month.month}&YY=#{month.year}"))
    html = Nokogiri::HTML.parse(source.force_encoding('ISO-8859-1'))

    day = nil

    html.css('table.tl1 tr').each do |row|
      next_day = row.css('td').try(:[], 1)
      next if next_day.nil?

      next_day = next_day.text&.squish.presence
      day = next_day.to_i if next_day.present?
      date = Date.new(month.year, month.month, day)

      extract_meeting_from_row(date, row)
    end
  end

  def extract_meeting_from_row(date, row)
    link = row.css('a').first
    if link.present?
      update_meeting_with_agenda(link)
    else
      update_meeting_without_agenda(date, row)
    end
  end

  def update_meeting_with_agenda(link)
    allris_id = (link['href'][/SILFDNR=(\d+)/, 1]).to_i
    meeting = meetings.find_or_create_by!(allris_id:)

    UpdateMeetingJob.perform_later(meeting)
  end

  def update_meeting_without_agenda(date, row)
    input = row.css('input[name=SILFDNR]').first

    if input.present?
      allris_id = input&.[](:value)
      meeting = meetings.find_or_create_by!(allris_id:)
      return if meeting.date.present?

      meeting.date = date
      time = row.css('td')[2].text
      meeting.start_time = time.split('-').first&.squish
      meeting.title = row.css('td')[5].text&.squish
      meeting.room = row.css('td.text4').first&.text
      meeting.save!
    end
  end
end
