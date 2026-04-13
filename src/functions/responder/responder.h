#pragma once

#include "processable.h"
#include "utils.h"

#include <map>
#include <tuple>
#include <chrono>
#include <mutex>
#include <vector>
#include <functional>

class Responder : public processable {
private:
    std::map<groupid_t, std::map<std::string, std::string>> replies;
    std::map<userid_t, std::tuple<groupid_t, std::string>> is_adding;
    std::map<groupid_t, bool> trigger_by;

    struct delayed_trigger_item {
        std::chrono::steady_clock::time_point due_time;
        groupid_t group_id = 0;
        userid_t user_id = 0;
        bot *p = nullptr;
    };

    std::vector<delayed_trigger_item> delayed_welcome_;
    std::mutex delayed_mutex_;

    void load();
    void save();
    std::string get_reply_message(const std::string &message,
                                  const msg_meta &conf);
    void send_reply_by_trigger(groupid_t group_id, userid_t user_id,
                               const std::string &trigger, bot *p);
    void flush_delayed_welcome(bot *p);

public:
    Responder();
    void process(std::string message, const msg_meta &conf);
    bool check(std::string message, const msg_meta &conf);
    bool reload(const msg_meta &conf) override;
    std::string help();
    void set_backup_files(archivist *p, const std::string &name);
    void set_callback(std::function<void(std::function<void(bot *p)>)> f);
};

DECLARE_FACTORY_FUNCTIONS_HEADER